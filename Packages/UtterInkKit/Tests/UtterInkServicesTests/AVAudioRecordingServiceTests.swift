import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class AVAudioRecordingServiceTests: XCTestCase {
    func testPermissionStatesAndRequestCounts() async throws {
        for (authorization, requested, expected, requestCount) in [
            (AudioRecordPermission.granted, false, PermissionState.granted, 0),
            (.denied, true, .denied, 0),
            (.undetermined, true, .granted, 1),
            (.undetermined, false, .denied, 1)
        ] {
            let fixture = try RecordingFixture(
                permission: PermissionFake(authorization: authorization, requestedResult: requested)
            )
            let result = await fixture.service.requestPermission()
            XCTAssertEqual(result, expected)
            XCTAssertEqual(fixture.permission.requestCount, requestCount)
        }
    }

    func testUnknownPermissionFailsClosedWithoutRequest() async throws {
        let permission = PermissionFake(authorization: .unknown, requestedResult: true)
        let fixture = try RecordingFixture(permission: permission)

        let result = await fixture.service.requestPermission()
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(permission.requestCount, 0)
    }

    func testConcurrentUndeterminedPermissionRequestsCoalesceIntoOneSystemRequest() async throws {
        let gate = FactoryGate()
        let permission = GatedPermissionFake(gate: gate, result: true)
        let fixture = try RecordingFixture(permissionClient: permission)
        let service = fixture.service

        let first = Task { await service.requestPermission() }
        let second = Task { await service.requestPermission() }
        await waitUntil { permission.requestCount >= 1 }
        XCTAssertEqual(permission.requestCount, 1)
        gate.open()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, .granted)
        XCTAssertEqual(secondResult, .granted)
        XCTAssertEqual(permission.requestCount, 1)
    }

    func testPublicConstructionHasNoPermissionOrCaptureSideEffect() throws {
        let parent = temporaryRecordingDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try TransientAudioStore(
            root: parent.appendingPathComponent("TransientAudio"),
            clock: RecordingTestClock()
        )
        let service = AVAudioRecordingService(store: store)
        XCTAssertNotNil(service as any AudioRecordingService)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: parent.path).count), 1)
    }

    func testStartSuccessWiresLevelsAndRejectsDuplicate() async throws {
        let fixture = try RecordingFixture()
        let levels = LevelRecorder()
        let handle = try await fixture.service.start { levels.append($0) }
        XCTAssertEqual(fixture.factory.makeCount, 1)
        XCTAssertEqual(fixture.session.startCount, 1)
        XCTAssertEqual(fixture.session.urls.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(fixture.session.urls.first).path))
        XCTAssertEqual(levels.values, [0.25])

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await fixture.service.start { _ in }
        }
        XCTAssertEqual(fixture.factory.makeCount, 1)
        await fixture.service.cancel(handle)
        XCTAssertEqual(fixture.session.cancelCount, 1)
        XCTAssertFalse(fixture.session.hasLevelCallback)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
    }

    func testReservationSurvivesActorReentrancyAndCallerCancellationCleansEverything() async throws {
        let gate = FactoryGate()
        let fixture = try RecordingFixture(factoryGate: gate)
        let factory = fixture.factory
        let service = fixture.service
        let first = Task { try await service.start { _ in } }
        await waitUntil { factory.makeCount == 1 }

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await service.start { _ in }
        }
        first.cancel()
        gate.open()
        await XCTAssertTaskDiagnostic(.cancelled, first)
        XCTAssertEqual(fixture.session.startCount, 0)
        XCTAssertEqual(fixture.session.cancelCount, 1)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)

        let replacement = try await service.start { _ in }
        await service.cancel(replacement)
    }

    func testFactoryAndSessionStartFailuresMapToAudioStartAndLeaveNoCAF() async throws {
        let factoryFailure = try RecordingFixture(factoryError: TestRecordingError.failed)
        await XCTAssertDiagnostic(.audioStart) {
            _ = try await factoryFailure.service.start { _ in }
        }
        XCTAssertTrue(try factoryFailure.cafFiles().isEmpty)

        let startFailure = try RecordingFixture(sessionStartError: TestRecordingError.failed)
        await XCTAssertDiagnostic(.audioStart) {
            _ = try await startFailure.service.start { _ in }
        }
        XCTAssertEqual(startFailure.session.cancelCount, 1)
        XCTAssertTrue(try startFailure.cafFiles().isEmpty)
    }

    func testStartVerifiesIssuedIdentityBeforeFactoryCanOpenSubstitutedSymlink() async throws {
        let fixture = try RecordingFixture()
        let outside = fixture.parent.appendingPathComponent("outside-marker")
        let marker = Data([0xCA, 0xFE])
        try marker.write(to: outside)
        let substitutingStore = PreFactorySubstitutionStore(
            base: fixture.store,
            outside: outside
        )
        fixture.factory.onMake = { url in
            try Data([0xDE, 0xAD]).write(to: url)
        }
        let service = AVAudioRecordingService(
            store: substitutingStore,
            permission: fixture.permission,
            factory: fixture.factory
        )

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await service.start { _ in }
        }

        XCTAssertEqual(fixture.factory.makeCount, 0)
        XCTAssertEqual(fixture.session.startCount, 0)
        XCTAssertEqual(try Data(contentsOf: outside), marker)
        let substituted = try XCTUnwrap(substitutingStore.substitutedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: substituted.path))
    }

    func testStartVerifiesIssuedIdentityAfterFactoryOpensAndBeforeSessionStarts() async throws {
        let fixture = try RecordingFixture()
        fixture.factory.onMake = { url in
            try FileManager.default.removeItem(at: url)
            try Data([0x77]).write(to: url)
        }

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await fixture.service.start { _ in }
        }
        XCTAssertEqual(fixture.session.startCount, 0)
        let substituted = try XCTUnwrap(fixture.session.urls.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: substituted.path))
        let preserved = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: substituted.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: []
            ).first { (try? Data(contentsOf: $0)) == Data([0x77]) }
        )
        XCTAssertFalse(preserved.lastPathComponent.hasSuffix(".caf"))
    }

    func testStopRequiresExactHandleStopsOnceAndRepeatReturnsSameURL() async throws {
        let fixture = try RecordingFixture()
        let handle = try await fixture.service.start { _ in }
        await XCTAssertDiagnostic(.audioFinalize) {
            _ = try await fixture.service.stop(RecordingHandle())
        }
        XCTAssertEqual(fixture.session.stopCount, 0)

        let url = try await fixture.service.stop(handle)
        XCTAssertEqual(fixture.session.stopCount, 1)
        let repeatedURL = try await fixture.service.stop(handle)
        XCTAssertEqual(repeatedURL, url)
        XCTAssertEqual(fixture.session.stopCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await fixture.service.cancel(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await fixture.service.cancel(handle)
        XCTAssertEqual(fixture.session.cancelCount, 0)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
    }

    func testActiveCancelAndUnknownCancelAreIdempotent() async throws {
        let fixture = try RecordingFixture()
        await fixture.service.cancel(RecordingHandle())
        let handle = try await fixture.service.start { _ in }
        let url = try XCTUnwrap(fixture.session.urls.first)
        await fixture.service.cancel(handle)
        await fixture.service.cancel(handle)
        XCTAssertEqual(fixture.session.cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
    }

    func testStopAndSealFailuresMapToAudioFinalizeCancelAndDelete() async throws {
        let stopFailure = try RecordingFixture(sessionStopError: TestRecordingError.failed)
        let stopHandle = try await stopFailure.service.start { _ in }
        await XCTAssertDiagnostic(.audioFinalize) {
            _ = try await stopFailure.service.stop(stopHandle)
        }
        XCTAssertEqual(stopFailure.session.stopCount, 1)
        XCTAssertEqual(stopFailure.session.cancelCount, 1)
        XCTAssertTrue(try stopFailure.cafFiles().isEmpty)

        let sealFailure = try RecordingFixture()
        let sealHandle = try await sealFailure.service.start { _ in }
        let url = try XCTUnwrap(sealFailure.session.urls.first)
        try FileManager.default.removeItem(at: url)
        await XCTAssertDiagnostic(.audioFinalize) {
            _ = try await sealFailure.service.stop(sealHandle)
        }
        XCTAssertEqual(sealFailure.session.stopCount, 1)
        XCTAssertEqual(sealFailure.session.cancelCount, 1)
        XCTAssertTrue(try sealFailure.cafFiles().isEmpty)
    }

    func testCancelWhileSealIsSuspendedWinsAndLeavesNoFinalizedCAF() async throws {
        let fixture = try RecordingFixture()
        let sealGate = FactoryGate()
        let gatedStore = SealGateStore(base: fixture.store, gate: sealGate)
        let service = AVAudioRecordingService(
            store: gatedStore,
            permission: fixture.permission,
            factory: fixture.factory
        )
        let handle = try await service.start { _ in }
        let stopping = Task { try await service.stop(handle) }
        await waitUntil { gatedStore.sealCount == 1 }
        await XCTAssertDiagnostic(.audioStart) {
            _ = try await service.start { _ in }
        }

        let cancelling = Task { await service.cancel(handle) }
        let session = fixture.session
        await waitUntil { session.cancelCount == 1 }
        sealGate.open()
        await cancelling.value
        await XCTAssertTaskDiagnostic(.audioFinalize, stopping)

        XCTAssertGreaterThanOrEqual(gatedStore.deleteCount, 1)
        XCTAssertEqual(fixture.session.stopCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.session.cancelCount, 1)
        XCTAssertFalse(fixture.session.hasLevelCallback)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
    }

    func testDeleteBarrierBlocksNewStartUntilActiveCancelCleanupFinishes() async throws {
        let fixture = try RecordingFixture()
        let gate = FactoryGate()
        let controlled = ControlledStore(base: fixture.store, deleteGate: gate)
        let service = AVAudioRecordingService(
            store: controlled,
            permission: fixture.permission,
            factory: fixture.factory
        )
        let handle = try await service.start { _ in }
        let cancelling = Task { await service.cancel(handle) }
        await waitUntil { controlled.deleteCount == 1 }

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await service.start { _ in }
        }
        gate.open()
        await cancelling.value

        let next = try await service.start { _ in }
        await service.cancel(next)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
    }

    func testFailedDeleteRetainsRetryableDebtUntilRepeatCancelSucceeds() async throws {
        let fixture = try RecordingFixture()
        let controlled = ControlledStore(base: fixture.store, deleteFailures: 2)
        let service = AVAudioRecordingService(
            store: controlled,
            permission: fixture.permission,
            factory: fixture.factory
        )
        let handle = try await service.start { _ in }

        await service.cancel(handle)
        XCTAssertEqual(controlled.deleteCount, 1)
        XCTAssertEqual(try fixture.cafFiles().count, 1)

        await service.cancel(handle)
        XCTAssertEqual(controlled.deleteCount, 2)
        XCTAssertEqual(try fixture.cafFiles().count, 1)

        await service.cancel(handle)
        XCTAssertEqual(controlled.deleteCount, 3)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
        XCTAssertEqual(fixture.session.cancelCount, 1)
    }

    func testFinalizedCancelRetainsDebtUntilRepeatCancelDeletesCAF() async throws {
        let fixture = try RecordingFixture()
        let controlled = ControlledStore(base: fixture.store, deleteFailures: 1)
        let service = AVAudioRecordingService(
            store: controlled,
            permission: fixture.permission,
            factory: fixture.factory
        )
        let handle = try await service.start { _ in }
        let url = try await service.stop(handle)

        await service.cancel(handle)
        XCTAssertEqual(controlled.deleteCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await service.cancel(handle)
        XCTAssertEqual(controlled.deleteCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFactoryAndSessionStartFailureCleanupDebtDrainsBeforeNextStart() async throws {
        do {
            let fixture = try RecordingFixture(factoryFailureCount: 1)
            let events = EventRecorder()
            fixture.factory.events = events
            fixture.session.events = events
            let controlled = ControlledStore(
                base: fixture.store,
                deleteFailures: 1,
                events: events
            )
            let service = AVAudioRecordingService(
                store: controlled,
                permission: fixture.permission,
                factory: fixture.factory
            )
            await XCTAssertDiagnostic(.audioStart) { _ = try await service.start { _ in } }
            XCTAssertEqual(try fixture.cafFiles().count, 1)

            events.removeAll()
            let handle = try await service.start { _ in }
            XCTAssertGreaterThanOrEqual(controlled.deleteCount, 2)
            XCTAssertEqual(
                Array(events.values.prefix(6)),
                ["delete", "make", "verify", "factory", "verify", "start"]
            )
            await service.cancel(handle)
            XCTAssertTrue(try fixture.cafFiles().isEmpty)
        }

        do {
            let fixture = try RecordingFixture(sessionStartFailureCount: 1)
            let controlled = ControlledStore(base: fixture.store, deleteFailures: 1)
            let service = AVAudioRecordingService(
                store: controlled,
                permission: fixture.permission,
                factory: fixture.factory
            )
            await XCTAssertDiagnostic(.audioStart) { _ = try await service.start { _ in } }
            XCTAssertEqual(try fixture.cafFiles().count, 1)

            let handle = try await service.start { _ in }
            await service.cancel(handle)
            XCTAssertTrue(try fixture.cafFiles().isEmpty)
        }
    }

    func testStopAndFinalizeFailureCleanupDebtDrainsBeforeNextStart() async throws {
        do {
            let fixture = try RecordingFixture(sessionStopFailureCount: 1)
            let controlled = ControlledStore(base: fixture.store, deleteFailures: 1)
            let service = AVAudioRecordingService(
                store: controlled,
                permission: fixture.permission,
                factory: fixture.factory
            )
            let handle = try await service.start { _ in }
            await XCTAssertDiagnostic(.audioFinalize) { _ = try await service.stop(handle) }
            XCTAssertEqual(try fixture.cafFiles().count, 1)

            let next = try await service.start { _ in }
            await service.cancel(next)
            XCTAssertTrue(try fixture.cafFiles().isEmpty)
        }

        do {
            let fixture = try RecordingFixture()
            let controlled = ControlledStore(base: fixture.store, deleteFailures: 1, sealFailures: 1)
            let service = AVAudioRecordingService(
                store: controlled,
                permission: fixture.permission,
                factory: fixture.factory
            )
            let handle = try await service.start { _ in }
            await XCTAssertDiagnostic(.audioFinalize) { _ = try await service.stop(handle) }
            XCTAssertEqual(try fixture.cafFiles().count, 1)

            let next = try await service.start { _ in }
            await service.cancel(next)
            XCTAssertTrue(try fixture.cafFiles().isEmpty)
        }
    }

    func testLevelCallbackBarrierWaitsForInflightCallbackAndRejectsPublishesAfterClose() async throws {
        let callbackEntered = DispatchSemaphore(value: 0)
        let callbackRelease = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let drainReturned = DispatchSemaphore(value: 0)
        let recorder = LevelRecorder()
        let publisher = SynchronousLevelPublisher { value in
            callbackEntered.signal()
            callbackRelease.wait()
            recorder.append(value)
            callbackReturned.signal()
        }

        DispatchQueue.global().async { publisher.publish(0.4) }
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        publisher.beginClose()
        DispatchQueue.global().async {
            publisher.waitForDrain()
            drainReturned.signal()
        }
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 0.05), .timedOut)
        callbackRelease.signal()
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 2), .success)

        publisher.publish(0.8)
        XCTAssertEqual(recorder.values, [0.4])
    }

    func testLevelPublishPoisedBeforeReservationIsDroppedWhenCloseBegins() {
        let reservationGate = OneShotSynchronousGate()
        let publishReturned = DispatchSemaphore(value: 0)
        let recorder = LevelRecorder()
        let publisher = SynchronousLevelPublisher(
            { recorder.append($0) },
            beforeReservation: { reservationGate.pause() }
        )

        DispatchQueue.global().async {
            publisher.publish(0.6)
            publishReturned.signal()
        }
        XCTAssertEqual(reservationGate.entered.wait(timeout: .now() + 2), .success)

        publisher.beginClose()
        reservationGate.release.signal()
        XCTAssertEqual(publishReturned.wait(timeout: .now() + 2), .success)
        publisher.waitForDrain()
        publisher.publish(0.9)

        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testLevelMeterUsesAllChannelsLegacyMappingAndAttackReleaseSmoothing() {
        let floatLevel = AudioLevelMeter.level(floatChannels: [
            [0, 0, 0, 0],
            [0.01, -0.01, 0.01, -0.01]
        ])
        XCTAssertEqual(floatLevel, sqrt(Float(0.01 * 14)), accuracy: 0.000_001)

        let int16Level = AudioLevelMeter.level(int16Channels: [
            [0, 0],
            [327, -327]
        ])
        XCTAssertEqual(int16Level, sqrt((Float(327) / 32_768) * 14), accuracy: 0.000_001)
        XCTAssertEqual(AudioLevelMeter.level(floatChannels: [[], [0, 0]]), 0)
        XCTAssertEqual(AudioLevelMeter.level(int16Channels: [[Int16.min, Int16.max]]), 1)
        XCTAssertEqual(AudioLevelMeter.smoothed(previous: 0.2, next: 0.6), 0.38, accuracy: 0.000_001)
        XCTAssertEqual(AudioLevelMeter.smoothed(previous: 0.6, next: 0.2), 0.552, accuracy: 0.000_001)
    }
}

private enum TestRecordingError: Error { case failed }

private final class PermissionFake: RecordingPermissionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let authorization: AudioRecordPermission
    private let requestedResult: Bool
    private var requests = 0

    init(authorization: AudioRecordPermission = .granted, requestedResult: Bool = true) {
        self.authorization = authorization
        self.requestedResult = requestedResult
    }

    var recordPermission: AudioRecordPermission { authorization }
    var requestCount: Int { lock.withLock { requests } }
    func requestRecordPermission() async -> Bool {
        lock.withLock { requests += 1 }
        return requestedResult
    }
}

private final class GatedPermissionFake: RecordingPermissionClient, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: FactoryGate
    private let result: Bool
    private var requests = 0

    init(gate: FactoryGate, result: Bool) {
        self.gate = gate
        self.result = result
    }

    var recordPermission: AudioRecordPermission { .undetermined }
    var requestCount: Int { lock.withLock { requests } }
    func requestRecordPermission() async -> Bool {
        lock.withLock { requests += 1 }
        await gate.wait()
        return result
    }
}

private final class RecordingSessionFake: RecordingSession, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingStartFailures: Int
    private var remainingStopFailures: Int
    private var starts = 0
    private var stops = 0
    private var cancels = 0
    private var storedURLs: [URL] = []
    private var levelCallback: (@Sendable (Float) -> Void)?
    var events: EventRecorder?

    init(startError: Error? = nil, stopError: Error? = nil, startFailureCount: Int = 0, stopFailureCount: Int = 0) {
        remainingStartFailures = startError == nil ? startFailureCount : .max
        remainingStopFailures = stopError == nil ? stopFailureCount : .max
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var cancelCount: Int { lock.withLock { cancels } }
    var urls: [URL] { lock.withLock { storedURLs } }
    var hasLevelCallback: Bool { lock.withLock { levelCallback != nil } }

    func configure(url: URL, levels: @escaping @Sendable (Float) -> Void) {
        lock.withLock {
            storedURLs.append(url)
            levelCallback = levels
        }
    }

    func start() throws {
        let result = lock.withLock { () -> (callback: (@Sendable (Float) -> Void)?, fails: Bool) in
            starts += 1
            let fails = remainingStartFailures > 0
            if remainingStartFailures != .max, remainingStartFailures > 0 { remainingStartFailures -= 1 }
            return (levelCallback, fails)
        }
        events?.append("start")
        if result.fails { throw TestRecordingError.failed }
        result.callback?(0.25)
    }

    func stop() throws {
        let fails = lock.withLock { () -> Bool in
            stops += 1
            levelCallback = nil
            let fails = remainingStopFailures > 0
            if remainingStopFailures != .max, remainingStopFailures > 0 { remainingStopFailures -= 1 }
            return fails
        }
        if fails { throw TestRecordingError.failed }
    }

    func cancel() {
        lock.withLock {
            cancels += 1
            levelCallback = nil
        }
    }
}

private final class RecordingFactoryFake: RecordingSessionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let session: RecordingSessionFake
    private var remainingFailures: Int
    private let gate: FactoryGate?
    private var makes = 0
    var onMake: (@Sendable (URL) throws -> Void)?
    var events: EventRecorder?

    init(session: RecordingSessionFake, error: Error? = nil, gate: FactoryGate? = nil, failureCount: Int = 0) {
        self.session = session
        remainingFailures = error == nil ? failureCount : .max
        self.gate = gate
    }

    var makeCount: Int { lock.withLock { makes } }
    func makeSession(
        for url: URL,
        levels: @escaping @Sendable (Float) -> Void
    ) async throws -> any RecordingSession {
        let fails = lock.withLock { () -> Bool in
            makes += 1
            let fails = remainingFailures > 0
            if remainingFailures != .max, remainingFailures > 0 { remainingFailures -= 1 }
            return fails
        }
        if let gate { await gate.wait() }
        if fails { throw TestRecordingError.failed }
        events?.append("factory")
        session.configure(url: url, levels: levels)
        try onMake?(url)
        return session
    }
}

private final class FactoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if opened { return true }
                continuations.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { continuations.removeAll() }
            return continuations
        }
        for continuation in pending { continuation.resume() }
    }
}

private final class SealGateStore: TransientAudioFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private let base: TransientAudioStore
    private let gate: FactoryGate
    private var seals = 0
    private var deletes = 0

    init(base: TransientAudioStore, gate: FactoryGate) {
        self.base = base
        self.gate = gate
    }

    var sealCount: Int { lock.withLock { seals } }
    var deleteCount: Int { lock.withLock { deletes } }

    func makeCaptureFile() async throws -> URL {
        try await base.makeCaptureFile()
    }

    func verifyForRecording(_ url: URL) async throws {
        try await base.verifyForRecording(url)
    }

    func seal(_ url: URL) async throws {
        lock.withLock { seals += 1 }
        await gate.wait()
        try await base.seal(url)
    }

    func delete(_ url: URL) async throws {
        lock.withLock { deletes += 1 }
        try await base.delete(url)
    }
}

private final class ControlledStore: TransientAudioFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private let base: TransientAudioStore
    private let deleteGate: FactoryGate?
    private var remainingDeleteFailures: Int
    private var remainingSealFailures: Int
    private var deletes = 0
    private let events: EventRecorder?

    init(
        base: TransientAudioStore,
        deleteGate: FactoryGate? = nil,
        deleteFailures: Int = 0,
        sealFailures: Int = 0,
        events: EventRecorder? = nil
    ) {
        self.base = base
        self.deleteGate = deleteGate
        remainingDeleteFailures = deleteFailures
        remainingSealFailures = sealFailures
        self.events = events
    }

    var deleteCount: Int { lock.withLock { deletes } }

    func makeCaptureFile() async throws -> URL {
        events?.append("make")
        return try await base.makeCaptureFile()
    }

    func verifyForRecording(_ url: URL) async throws {
        events?.append("verify")
        try await base.verifyForRecording(url)
    }

    func seal(_ url: URL) async throws {
        let fails = lock.withLock { () -> Bool in
            guard remainingSealFailures > 0 else { return false }
            remainingSealFailures -= 1
            return true
        }
        if fails { throw TestRecordingError.failed }
        try await base.seal(url)
    }

    func delete(_ url: URL) async throws {
        events?.append("delete")
        let fails = lock.withLock { () -> Bool in
            deletes += 1
            guard remainingDeleteFailures > 0 else { return false }
            remainingDeleteFailures -= 1
            return true
        }
        if let deleteGate { await deleteGate.wait() }
        if fails { throw TestRecordingError.failed }
        try await base.delete(url)
    }
}

private final class PreFactorySubstitutionStore: TransientAudioFileStore, @unchecked Sendable {
    private let lock = NSLock()
    private let base: TransientAudioStore
    private let outside: URL
    private var capturedURL: URL?

    init(base: TransientAudioStore, outside: URL) {
        self.base = base
        self.outside = outside
    }

    var substitutedURL: URL? { lock.withLock { capturedURL } }

    func makeCaptureFile() async throws -> URL {
        let url = try await base.makeCaptureFile()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        lock.withLock { capturedURL = url }
        return url
    }

    func verifyForRecording(_ url: URL) async throws {
        try await base.verifyForRecording(url)
    }

    func seal(_ url: URL) async throws {
        try await base.seal(url)
    }

    func delete(_ url: URL) async throws {
        try await base.delete(url)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] { lock.withLock { stored } }
    func append(_ event: String) { lock.withLock { stored.append(event) } }
    func removeAll() { lock.withLock { stored.removeAll() } }
}

private final class LevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    var values: [Float] { lock.withLock { stored } }
    func append(_ value: Float) { lock.withLock { stored.append(value) } }
}

private final class OneShotSynchronousGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var used = false

    func pause() {
        let shouldPause = lock.withLock { () -> Bool in
            guard !used else { return false }
            used = true
            return true
        }
        guard shouldPause else { return }
        entered.signal()
        release.wait()
    }
}

private final class RecordingFixture {
    let parent: URL
    let store: TransientAudioStore
    let permission: PermissionFake
    let session: RecordingSessionFake
    let factory: RecordingFactoryFake
    let service: AVAudioRecordingService

    init(
        permission: PermissionFake = PermissionFake(),
        permissionClient: (any RecordingPermissionClient)? = nil,
        factoryGate: FactoryGate? = nil,
        factoryError: Error? = nil,
        factoryFailureCount: Int = 0,
        sessionStartError: Error? = nil,
        sessionStopError: Error? = nil,
        sessionStartFailureCount: Int = 0,
        sessionStopFailureCount: Int = 0
    ) throws {
        parent = temporaryRecordingDirectory()
        store = try TransientAudioStore(
            root: parent.appendingPathComponent("TransientAudio", isDirectory: true),
            clock: RecordingTestClock()
        )
        self.permission = permission
        session = RecordingSessionFake(
            startError: sessionStartError,
            stopError: sessionStopError,
            startFailureCount: sessionStartFailureCount,
            stopFailureCount: sessionStopFailureCount
        )
        factory = RecordingFactoryFake(
            session: session,
            error: factoryError,
            gate: factoryGate,
            failureCount: factoryFailureCount
        )
        service = AVAudioRecordingService(
            store: store,
            permission: permissionClient ?? permission,
            factory: factory
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: parent)
    }

    func cafFiles() throws -> [URL] {
        let root = parent.appendingPathComponent("TransientAudio", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.pathExtension == "caf" }
    }
}

private struct RecordingTestClock: AppClock {
    var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    func sleep(for duration: Duration) async throws {}
}

private func temporaryRecordingDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("UtterInk-recording-tests-\(UUID().uuidString)", isDirectory: true)
}

private func XCTAssertDiagnostic(
    _ expected: DiagnosticCode,
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let code as DiagnosticCode {
        XCTAssertEqual(code, expected, file: file, line: line)
    } catch {
        XCTFail("Escaped non-diagnostic error: \(error)", file: file, line: line)
    }
}

private func XCTAssertTaskDiagnostic<T>(
    _ expected: DiagnosticCode,
    _ task: Task<T, Error>,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await task.value
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let code as DiagnosticCode {
        XCTAssertEqual(code, expected, file: file, line: line)
    } catch {
        XCTFail("Escaped non-diagnostic error: \(error)", file: file, line: line)
    }
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    XCTFail("Condition did not become true")
}
