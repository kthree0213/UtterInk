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
        let first = Task { try await fixture.service.start { _ in } }
        await waitUntil { fixture.factory.makeCount == 1 }

        await XCTAssertDiagnostic(.audioStart) {
            _ = try await fixture.service.start { _ in }
        }
        first.cancel()
        gate.open()
        await XCTAssertTaskDiagnostic(.cancelled, first)
        XCTAssertEqual(fixture.session.startCount, 0)
        XCTAssertEqual(fixture.session.cancelCount, 1)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)

        let replacement = try await fixture.service.start { _ in }
        await fixture.service.cancel(replacement)
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
        await waitUntil { gatedStore.deleteCount >= 1 }
        sealGate.open()
        await cancelling.value
        await XCTAssertTaskDiagnostic(.audioFinalize, stopping)

        XCTAssertGreaterThanOrEqual(gatedStore.deleteCount, 1)
        XCTAssertEqual(fixture.session.stopCount, 1)
        XCTAssertGreaterThanOrEqual(fixture.session.cancelCount, 1)
        XCTAssertFalse(fixture.session.hasLevelCallback)
        XCTAssertTrue(try fixture.cafFiles().isEmpty)
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

private final class RecordingSessionFake: RecordingSession, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: Error?
    private let stopError: Error?
    private var starts = 0
    private var stops = 0
    private var cancels = 0
    private var storedURLs: [URL] = []
    private var levelCallback: (@Sendable (Float) -> Void)?

    init(startError: Error? = nil, stopError: Error? = nil) {
        self.startError = startError
        self.stopError = stopError
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
        let callback = lock.withLock { () -> (@Sendable (Float) -> Void)? in
            starts += 1
            return levelCallback
        }
        if let startError { throw startError }
        callback?(0.25)
    }

    func stop() throws {
        lock.withLock {
            stops += 1
            levelCallback = nil
        }
        if let stopError { throw stopError }
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
    private let error: Error?
    private let gate: FactoryGate?
    private var makes = 0

    init(session: RecordingSessionFake, error: Error? = nil, gate: FactoryGate? = nil) {
        self.session = session
        self.error = error
        self.gate = gate
    }

    var makeCount: Int { lock.withLock { makes } }
    func makeSession(
        for url: URL,
        levels: @escaping @Sendable (Float) -> Void
    ) async throws -> any RecordingSession {
        lock.withLock { makes += 1 }
        if let gate { await gate.wait() }
        if let error { throw error }
        session.configure(url: url, levels: levels)
        return session
    }
}

private final class FactoryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func open() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
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

private final class LevelRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []
    var values: [Float] { lock.withLock { stored } }
    func append(_ value: Float) { lock.withLock { stored.append(value) } }
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
        factoryGate: FactoryGate? = nil,
        factoryError: Error? = nil,
        sessionStartError: Error? = nil,
        sessionStopError: Error? = nil
    ) throws {
        parent = temporaryRecordingDirectory()
        store = try TransientAudioStore(
            root: parent.appendingPathComponent("TransientAudio", isDirectory: true),
            clock: RecordingTestClock()
        )
        self.permission = permission
        session = RecordingSessionFake(startError: sessionStartError, stopError: sessionStopError)
        factory = RecordingFactoryFake(session: session, error: factoryError, gate: factoryGate)
        service = AVAudioRecordingService(store: store, permission: permission, factory: factory)
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
