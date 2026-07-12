import XCTest
@testable import UtterInkCore
@testable import UtterInkServices

@MainActor
final class HotkeyServiceTests: XCTestCase {
    func testHoldToTalkSuppressesRepeatsAndIgnoresExtraKeyUps() async {
        let backend = HotkeyBackendFake()
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        let service = KeyboardShortcutsHotkeyService(
            mode: .holdToTalk,
            onEvent: { events.append($0) },
            backend: backend
        )

        backend.sendKeyDown()
        backend.sendKeyDown()
        backend.sendKeyUp()
        backend.sendKeyUp()
        backend.sendKeyDown()
        backend.sendKeyUp()
        await waitUntil { events.count == 4 }

        XCTAssertEqual(
            events,
            [.startRequested, .stopRequested, .startRequested, .stopRequested]
        )
        XCTAssertFalse(Mirror(reflecting: service).children.contains { $0.label == "isRecording" })
        service.teardown()
    }

    func testToggleUsesNextEventLatchAndKeyUpOnlyReleasesRepeatSuppression() async {
        let backend = HotkeyBackendFake()
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        let service = KeyboardShortcutsHotkeyService(
            mode: .toggle,
            onEvent: { events.append($0) },
            backend: backend
        )

        backend.sendKeyDown()
        backend.sendKeyDown()
        backend.sendKeyUp()
        backend.sendKeyUp()
        backend.sendKeyDown()
        backend.sendKeyDown()
        backend.sendKeyUp()
        backend.sendKeyDown()
        await waitUntil { events.count == 3 }

        XCTAssertEqual(events, [.startRequested, .stopRequested, .startRequested])
        XCTAssertFalse(Mirror(reflecting: service).children.contains { $0.label == "isRecording" })
        service.teardown()
    }

    func testCallbacksRunOnMainActorInAcceptedPhysicalOrder() async {
        let backend = HotkeyBackendFake()
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        var allCallbacksWereOnMainThread = true
        let service = KeyboardShortcutsHotkeyService(
            mode: .holdToTalk,
            onEvent: { event in
                MainActor.preconditionIsolated()
                allCallbacksWereOnMainThread = allCallbacksWereOnMainThread && Thread.isMainThread
                events.append(event)
            },
            backend: backend
        )

        await Task.detached {
            backend.sendKeyDown()
            backend.sendKeyUp()
            backend.sendKeyDown()
            backend.sendKeyUp()
        }.value
        await waitUntil { events.count == 4 }

        XCTAssertTrue(allCallbacksWereOnMainThread)
        XCTAssertEqual(
            events,
            [.startRequested, .stopRequested, .startRequested, .stopRequested]
        )
        service.teardown()
    }

    func testConflictIndicatorReportsInjectedConflictWithoutOwnerClaims() {
        for conflict in [false, true] {
            let backend = HotkeyBackendFake(hasConflict: conflict)
            let service = KeyboardShortcutsHotkeyService(
                mode: .toggle,
                onEvent: { _ in },
                backend: backend
            )

            XCTAssertEqual(service.hasConflict, conflict)
            XCTAssertEqual(backend.conflictQueryCount, 1)
            service.teardown()
        }
    }

    func testProbeYieldsOncePerAcceptedPhysicalKeyDownAndFinishesOnTeardown() async {
        let backend = HotkeyBackendFake()
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        let service = KeyboardShortcutsHotkeyService(
            mode: .toggle,
            onEvent: { events.append($0) },
            backend: backend
        )
        let stream = service.probeEvents()
        let collected = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        backend.sendKeyDown()
        backend.sendKeyDown()
        backend.sendKeyUp()
        backend.sendKeyDown()
        backend.sendKeyDown()
        await waitUntil { events.count == 2 }
        service.teardown()

        let probeCount = await collected.value
        XCTAssertEqual(probeCount, 2)
        XCTAssertEqual(events, [.startRequested, .stopRequested])
    }

    func testTeardownIsIdempotentRemovesFixedHandlersAndPreventsFutureCallbacks() async {
        let backend = HotkeyBackendFake()
        var events: [KeyboardShortcutsHotkeyService.Event] = []
        let service = KeyboardShortcutsHotkeyService(
            mode: .holdToTalk,
            onEvent: { events.append($0) },
            backend: backend
        )
        XCTAssertEqual(backend.installCount, 1)

        backend.sendKeyDown()
        await waitUntil { events == [.startRequested] }
        service.teardown()
        service.teardown()
        backend.sendKeyUp()
        backend.sendKeyDown()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(backend.removeCount, 1)
        XCTAssertEqual(events, [.startRequested])
    }

    func testFixedRecorderNameIsStable() {
        XCTAssertEqual(KeyboardShortcutsHotkeyService.shortcutName.rawValue, "utterink.dictation")
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for hotkey callback")
    }
}

private final class HotkeyBackendFake: HotkeyEventBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let conflict: Bool
    private var keyDown: (@Sendable () -> Void)?
    private var keyUp: (@Sendable () -> Void)?
    private var installs = 0
    private var removals = 0
    private var conflictQueries = 0

    init(hasConflict: Bool = false) {
        conflict = hasConflict
    }

    var installCount: Int {
        lock.withLock { installs }
    }

    var removeCount: Int {
        lock.withLock { removals }
    }

    var conflictQueryCount: Int {
        lock.withLock { conflictQueries }
    }

    func conflictDetected() -> Bool {
        lock.withLock { conflictQueries += 1 }
        return conflict
    }

    func install(
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) {
        lock.withLock {
            installs += 1
            keyDown = onKeyDown
            keyUp = onKeyUp
        }
    }

    func removeHandlers() {
        lock.withLock {
            removals += 1
            keyDown = nil
            keyUp = nil
        }
    }

    func sendKeyDown() {
        let callback = lock.withLock { keyDown }
        callback?()
    }

    func sendKeyUp() {
        let callback = lock.withLock { keyUp }
        callback?()
    }
}
