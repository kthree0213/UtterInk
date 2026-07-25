import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class DeliveryCoordinatorTests: XCTestCase {
    func testOnboardingAlwaysUsesOnlySinkForBothPreferences() async {
        for preference in [DeliveryPreference.automaticPaste, .copyOnly] {
            let fixture = makeFixture()
            let token = effectToken()

            let outcome = await fixture.coordinator.deliver(
                text: "private result",
                to: .onboardingTest,
                preference: preference,
                token: token
            )

            XCTAssertEqual(outcome, .deliveredToOnboardingTest)
            let deliveries = await fixture.sink.recorded()
            let pasteboardStats = await fixture.pasteboard.stats()
            let targetStats = await fixture.target.stats()
            XCTAssertEqual(
                deliveries,
                [OnboardingDelivery(sessionID: token.sessionID, text: "private result")]
            )
            XCTAssertEqual(pasteboardStats, PasteboardStats())
            XCTAssertEqual(targetStats, TargetStats())
        }
    }

    func testCopyOnlyPreferenceReplacesOnceForEveryNonOnboardingTarget() async {
        for target in [DeliveryTarget.copyOnly, .external(DeliveryTargetID())] {
            let fixture = makeFixture()
            let outcome = await fixture.coordinator.deliver(
                text: "copied",
                to: target,
                preference: .copyOnly,
                token: effectToken()
            )

            XCTAssertEqual(outcome, .copiedByPreference)
            let currentText = await fixture.pasteboard.currentText()
            let pasteboardStats = await fixture.pasteboard.stats()
            let targetStats = await fixture.target.stats()
            XCTAssertEqual(currentText, "copied")
            XCTAssertEqual(
                pasteboardStats,
                PasteboardStats(directWrites: 1)
            )
            XCTAssertEqual(targetStats, TargetStats())
        }
    }

    func testAutomaticCopyOnlyTargetIsAZeroMutationManualFallback() async {
        let fixture = makeFixture()
        let before = await fixture.pasteboard.state()

        let outcome = await fixture.coordinator.deliver(
            text: "must not be written",
            to: .copyOnly,
            preference: .automaticPaste,
            token: effectToken()
        )

        XCTAssertEqual(outcome, .manualCopyRequired(.deliveryTargetUnavailable))
        let after = await fixture.pasteboard.state()
        let pasteboardStats = await fixture.pasteboard.stats()
        let targetStats = await fixture.target.stats()
        XCTAssertEqual(after, before)
        XCTAssertEqual(pasteboardStats, PasteboardStats())
        XCTAssertEqual(targetStats, TargetStats())
    }

    func testExplicitCopyIsDistinctAndNeverRestored() async {
        let fixture = makeFixture()

        let outcome = await fixture.coordinator.copyExplicitly(
            text: "explicit",
            token: effectToken()
        )

        XCTAssertEqual(outcome, .copiedByUser)
        XCTAssertNotEqual(outcome, .copiedByPreference)
        let currentText = await fixture.pasteboard.currentText()
        let pasteboardStats = await fixture.pasteboard.stats()
        XCTAssertEqual(currentText, "explicit")
        XCTAssertEqual(
            pasteboardStats,
            PasteboardStats(directWrites: 1)
        )
    }

    func testFailedAndPrecancelledDirectCopiesNeverClaimSuccess() async {
        let failedPasteboard = PasteboardFake(directWriteSucceeds: false)
        let failedFixture = makeFixture(pasteboard: failedPasteboard)
        let failedOutcome = await failedFixture.coordinator.copyExplicitly(
            text: "must not appear",
            token: effectToken()
        )
        let failedText = await failedPasteboard.currentText()
        let failedCount = await failedPasteboard.changeCount()
        XCTAssertEqual(failedOutcome, .manualCopyRequired(.deliveryPasteboardChanged))
        XCTAssertEqual(failedText, "original")
        XCTAssertEqual(failedCount, 1)

        let startGate = AsyncGate()
        let cancelledFixture = makeFixture()
        let cancelled = Task {
            await startGate.wait()
            return await cancelledFixture.coordinator.copyExplicitly(
                text: "cancelled",
                token: effectToken()
            )
        }
        cancelled.cancel()
        await startGate.open()
        let cancelledOutcome = await cancelled.value
        let cancelledText = await cancelledFixture.pasteboard.currentText()
        let cancelledStats = await cancelledFixture.pasteboard.stats()
        XCTAssertEqual(cancelledOutcome, .manualCopyRequired(.cancelled))
        XCTAssertEqual(cancelledText, "original")
        XCTAssertEqual(cancelledStats, PasteboardStats())
    }

    func testCancellationAtDirectAndAutomaticPrewriteBoundariesDoesNotWrite() async {
        let directGate = AsyncGate()
        let directPasteboard = PasteboardFake(directGate: directGate)
        let directFixture = makeFixture(pasteboard: directPasteboard)
        let directTask = Task {
            await directFixture.coordinator.copyExplicitly(
                text: "cancelled direct",
                token: effectToken()
            )
        }
        await directGate.waitUntilEntered()
        directTask.cancel()
        await directGate.open()
        let directOutcome = await directTask.value
        let directState = await directPasteboard.state()
        let directStats = await directPasteboard.stats()
        XCTAssertEqual(directOutcome, .manualCopyRequired(.cancelled))
        XCTAssertEqual(directState, PasteboardState(items: [PasteboardFake.textItem("original")], changeCount: 1))
        XCTAssertEqual(directStats, PasteboardStats(directWrites: 1))

        let compareGate = AsyncGate()
        let automaticPasteboard = PasteboardFake(compareGate: compareGate)
        let automaticFixture = makeFixture(pasteboard: automaticPasteboard)
        let automaticTask = Task {
            await automaticFixture.coordinator.deliver(
                text: "cancelled automatic",
                to: .external(automaticFixture.target.id),
                preference: .automaticPaste,
                token: effectToken()
            )
        }
        await compareGate.waitUntilEntered()
        automaticTask.cancel()
        await compareGate.open()
        let automaticOutcome = await automaticTask.value
        let automaticText = await automaticPasteboard.currentText()
        let automaticStats = await automaticPasteboard.stats()
        let automaticTargetStats = await automaticFixture.target.stats()
        XCTAssertEqual(automaticOutcome, .manualCopyRequired(.cancelled))
        XCTAssertEqual(automaticText, "original")
        XCTAssertEqual(
            automaticStats,
            PasteboardStats(captures: 1, compareWrites: 1)
        )
        XCTAssertEqual(automaticTargetStats, TargetStats(validations: 1))
    }

    func testPrewriteTargetUnavailableOrChangedNeverWrites() async {
        for (validation, code) in [
            (TargetValidation.unavailable, DiagnosticCode.deliveryTargetUnavailable),
            (.changed, .deliveryTargetChanged)
        ] {
            let target = TargetFake(validations: [validation])
            let fixture = makeFixture(target: target)

            let outcome = await fixture.coordinator.deliver(
                text: "result",
                to: .external(target.id),
                preference: .automaticPaste,
                token: effectToken()
            )

            XCTAssertEqual(outcome, .manualCopyRequired(code))
            let currentText = await fixture.pasteboard.currentText()
            let pasteboardStats = await fixture.pasteboard.stats()
            let targetStats = await target.stats()
            XCTAssertEqual(currentText, "original")
            XCTAssertEqual(
                pasteboardStats,
                PasteboardStats(captures: 1)
            )
            XCTAssertEqual(
                targetStats,
                TargetStats(validations: 1)
            )
        }
    }

    func testUserCopyBeforeCompareWriteIsPreservedWithoutDispatch() async {
        let pasteboard = PasteboardFake(changeBeforeCompare: "new user copy")
        let fixture = makeFixture(pasteboard: pasteboard)

        let outcome = await fixture.coordinator.deliver(
            text: "result",
            to: .external(fixture.target.id),
            preference: .automaticPaste,
            token: effectToken()
        )

        XCTAssertEqual(outcome, .manualCopyRequired(.deliveryPasteboardChanged))
        let currentText = await pasteboard.currentText()
        let pasteboardStats = await pasteboard.stats()
        let targetStats = await fixture.target.stats()
        XCTAssertEqual(currentText, "new user copy")
        XCTAssertEqual(
            pasteboardStats,
            PasteboardStats(captures: 1, compareWrites: 1, userCopies: 1)
        )
        XCTAssertEqual(targetStats, TargetStats(validations: 1))
    }

    func testPostwriteTargetOrDispatchFailureRestoresExactlyOnce() async {
        for (dispatch, code) in [
            (TargetDispatch.changed, DiagnosticCode.deliveryTargetChanged),
            (.failed, .deliveryDispatch)
        ] {
            let target = TargetFake(dispatches: [dispatch])
            let fixture = makeFixture(target: target)

            let outcome = await fixture.coordinator.deliver(
                text: "result",
                to: .external(target.id),
                preference: .automaticPaste,
                token: effectToken()
            )

            XCTAssertEqual(outcome, .manualCopyRequired(code))
            let currentText = await fixture.pasteboard.currentText()
            let pasteboardStats = await fixture.pasteboard.stats()
            let targetStats = await target.stats()
            let changeCount = await fixture.pasteboard.changeCount()
            XCTAssertEqual(currentText, "original")
            XCTAssertEqual(
                pasteboardStats,
                PasteboardStats(
                    captures: 1,
                    compareWrites: 1,
                    restoreAttempts: 1,
                    restores: 1
                )
            )
            XCTAssertEqual(
                targetStats,
                TargetStats(validations: 1, dispatchAttempts: 1)
            )
            XCTAssertEqual(changeCount, 3)
        }
    }

    func testUserCopyDuringSettleIsNeverOverwritten() async {
        let gate = AsyncGate()
        let clock = GateClock(gate: gate)
        let fixture = makeFixture(clock: clock)
        let task = Task {
            await fixture.coordinator.deliver(
                text: "result",
                to: .external(fixture.target.id),
                preference: .automaticPaste,
                token: effectToken()
            )
        }
        await gate.waitUntilEntered()
        await fixture.pasteboard.userCopy("newer")
        await gate.open()

        let outcome = await task.value
        let currentText = await fixture.pasteboard.currentText()
        let pasteboardStats = await fixture.pasteboard.stats()
        let eventPosts = await fixture.target.eventPostCount()
        let changeCount = await fixture.pasteboard.changeCount()
        XCTAssertEqual(outcome, .pasteEventDispatched)
        XCTAssertEqual(currentText, "newer")
        XCTAssertEqual(
            pasteboardStats,
            PasteboardStats(
                captures: 1,
                compareWrites: 1,
                restoreAttempts: 1,
                userCopies: 1
            )
        )
        XCTAssertEqual(eventPosts, 2)
        XCTAssertEqual(changeCount, 3)
    }

    func testCancellationAfterWriteRestoresBeforeLeaseReleaseAndPostsNothing() async {
        let dispatchGate = AsyncGate()
        let target = TargetFake(dispatchGate: dispatchGate)
        let fixture = makeFixture(target: target)
        let task = Task {
            await fixture.coordinator.deliver(
                text: "result",
                to: .external(target.id),
                preference: .automaticPaste,
                token: effectToken()
            )
        }
        await dispatchGate.waitUntilEntered()
        task.cancel()
        await dispatchGate.open()

        let outcome = await task.value
        let currentText = await fixture.pasteboard.currentText()
        let eventPosts = await target.eventPostCount()
        let pasteboardStats = await fixture.pasteboard.stats()
        XCTAssertEqual(outcome, .manualCopyRequired(.cancelled))
        XCTAssertEqual(currentText, "original")
        XCTAssertEqual(eventPosts, 0)
        XCTAssertEqual(
            pasteboardStats,
            PasteboardStats(
                captures: 1,
                compareWrites: 1,
                restoreAttempts: 1,
                restores: 1
            )
        )
    }

    func testLeaseSerializesExplicitCopyUntilAutomaticCleanupCompletes() async {
        let settleGate = AsyncGate()
        let fixture = makeFixture(clock: GateClock(gate: settleGate))
        let first = Task {
            await fixture.coordinator.deliver(
                text: "automatic",
                to: .external(fixture.target.id),
                preference: .automaticPaste,
                token: effectToken()
            )
        }
        await settleGate.waitUntilEntered()
        let second = Task {
            await fixture.coordinator.copyExplicitly(text: "explicit", token: effectToken())
        }
        await Task.yield()
        await Task.yield()

        let statsWhileBlocked = await fixture.pasteboard.stats()
        XCTAssertEqual(statsWhileBlocked.directWrites, 0)
        await settleGate.open()
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let currentText = await fixture.pasteboard.currentText()
        let finalStats = await fixture.pasteboard.stats()
        XCTAssertEqual(firstOutcome, .pasteEventDispatched)
        XCTAssertEqual(secondOutcome, .copiedByUser)
        XCTAssertEqual(currentText, "explicit")
        XCTAssertEqual(
            finalStats,
            PasteboardStats(
                captures: 1,
                directWrites: 1,
                compareWrites: 1,
                restoreAttempts: 1,
                restores: 1
            )
        )
    }

    @MainActor
    func testPasteboardBoundsUnreadableCountDriftAndPayloadPrivateDebugging() async {
        let limit = 16 * 1_024 * 1_024
        XCTAssertEqual(PasteboardClient.checkedTotal(0, adding: limit), limit)
        XCTAssertNil(PasteboardClient.checkedTotal(0, adding: limit + 1))
        XCTAssertNil(PasteboardClient.checkedTotal(Int.max, adding: 1))

        let exactPlatform = PasteboardPlatformFake(data: Data(repeating: 1, count: limit))
        let exactClient = PasteboardClient(clock: StaticClock(), platform: exactPlatform)
        guard case let .captured(snapshot) = exactClient.capture() else {
            return XCTFail("exactly 16 MiB must be capturable")
        }
        XCTAssertFalse(String(reflecting: snapshot).contains("payload-canary"))

        let cases = [
            PasteboardPlatformFake(data: Data(repeating: 1, count: limit + 1)),
            PasteboardPlatformFake(data: nil),
            PasteboardPlatformFake(data: Data()),
            PasteboardPlatformFake(data: Data([1]), changeCountAfterRead: 2)
        ]
        for platform in cases {
            let client = PasteboardClient(clock: StaticClock(), platform: platform)
            guard case .unsafe = client.capture() else {
                return XCTFail("unsafe pasteboard input was accepted")
            }
        }

        let timedClock = MutableClock()
        let timedPlatform = PasteboardPlatformFake(data: Data([1])) {
            timedClock.advance(by: 0.501)
        }
        let timedClient = PasteboardClient(clock: timedClock, platform: timedPlatform)
        guard case .unsafe = timedClient.capture() else {
            return XCTFail("over-budget materialization was accepted")
        }
    }

    @MainActor
    func testPasteboardCaptureAndGuardedRestorePreserveEveryByteAndOrder() {
        let original = [
            PasteboardItemSnapshot(
                representations: [
                    PasteboardRepresentation(type: "type.first", data: Data([0, 1, 2])),
                    PasteboardRepresentation(type: "type.second", data: Data("payload-canary".utf8))
                ]
            ),
            PasteboardItemSnapshot(
                representations: [
                    PasteboardRepresentation(type: "type.third", data: Data([255, 8, 7]))
                ]
            )
        ]
        let platform = OrderedPasteboardPlatformFake(items: original, changeCount: 9)
        let client = PasteboardClient(clock: StaticClock(), platform: platform)
        guard case let .captured(snapshot) = client.capture() else {
            return XCTFail("complete readable pasteboard was rejected")
        }
        XCTAssertEqual(snapshot.items, original)
        XCTAssertFalse(String(reflecting: snapshot).contains("payload-canary"))

        guard case let .written(ownedCount) = client.compareAndWrite(
            text: "temporary",
            expectedChangeCount: 9
        ) else {
            return XCTFail("unchanged pasteboard was not written")
        }
        XCTAssertEqual(ownedCount, 10)
        XCTAssertTrue(client.guardedRestore(snapshot, ownedChangeCount: ownedCount))
        XCTAssertEqual(platform.items, original)
        XCTAssertEqual(platform.changeCount, 11)
    }

    @MainActor
    func testTargetTrackerRejectsIdentityAndEpochChangesAndUsesCapturedPID() async {
        let token = effectToken(generation: 91)
        let stableIdentity = TargetIdentityFake()
        let platform = TargetSystemPlatformFake(
            focus: .target(TargetFocusReference(pid: 4242, opaqueIdentity: stableIdentity))
        )
        let tracker = TargetTracker(clock: StaticClock(), platform: platform)
        guard case let .external(targetID) = await tracker.snapshotTarget() else {
            return XCTFail("stable editable external target was not captured")
        }

        let stableValidation = await tracker.validate(targetID: targetID, token: token)
        let stableDispatch = await tracker.revalidateAndDispatch(targetID: targetID, token: token)
        XCTAssertEqual(stableValidation, .valid)
        XCTAssertEqual(stableDispatch, .dispatched)
        XCTAssertEqual(platform.postedPIDs, [4242, 4242])
        XCTAssertEqual(platform.seenTokens, [token])

        let mutations: [(TargetIdentityFake) -> TargetIdentityFake] = [
            { $0.copy(process: UUID()) },
            { $0.copy(window: UUID()) },
            { $0.copy(element: UUID()) },
            { $0.copy(editable: false) },
            { $0.copy(alive: false) }
        ]
        for mutate in mutations {
            let original = TargetIdentityFake()
            let changedPlatform = TargetSystemPlatformFake(
                focus: .target(TargetFocusReference(pid: 5151, opaqueIdentity: original))
            )
            let changedTracker = TargetTracker(clock: StaticClock(), platform: changedPlatform)
            guard case let .external(changedID) = await changedTracker.snapshotTarget() else {
                return XCTFail("fixture target was not captured")
            }
            changedPlatform.focus = .target(
                TargetFocusReference(pid: 5151, opaqueIdentity: mutate(original))
            )
            let changedDispatch = await changedTracker.revalidateAndDispatch(
                targetID: changedID,
                token: token
            )
            XCTAssertEqual(changedDispatch, .changed)
            XCTAssertTrue(changedPlatform.postedPIDs.isEmpty)
        }

        let epochIdentity = TargetIdentityFake()
        let epochPlatform = TargetSystemPlatformFake(
            focus: .target(TargetFocusReference(pid: 6262, opaqueIdentity: epochIdentity))
        )
        let epochTracker = TargetTracker(clock: StaticClock(), platform: epochPlatform)
        guard case let .external(epochID) = await epochTracker.snapshotTarget() else {
            return XCTFail("epoch fixture target was not captured")
        }
        // A redundant notification from the same custom editor must not make
        // a still-focused target stale.
        epochPlatform.emitChange()
        let stableEpochDispatch = await epochTracker.revalidateAndDispatch(
            targetID: epochID,
            token: token
        )
        XCTAssertEqual(stableEpochDispatch, .dispatched)
        XCTAssertEqual(epochPlatform.postedPIDs, [6262, 6262])

        let changedIdentity = epochIdentity.copy(element: UUID())
        epochPlatform.focus = .target(
            TargetFocusReference(pid: 6262, opaqueIdentity: changedIdentity)
        )
        epochPlatform.emitChange()
        let changedEpochDispatch = await epochTracker.revalidateAndDispatch(
            targetID: epochID,
            token: token
        )
        XCTAssertEqual(changedEpochDispatch, .changed)
        XCTAssertEqual(epochPlatform.postedPIDs, [6262, 6262])

        let incapablePlatform = TargetSystemPlatformFake(
            focus: .target(
                TargetFocusReference(pid: 7373, opaqueIdentity: TargetIdentityFake())
            ),
            postingAvailable: false
        )
        let incapableTracker = TargetTracker(clock: StaticClock(), platform: incapablePlatform)
        let incapableSnapshot = await incapableTracker.snapshotTarget()
        XCTAssertEqual(incapableSnapshot, .copyOnly)
        let incapableDispatch = await incapableTracker.revalidateAndDispatch(
            targetID: DeliveryTargetID(),
            token: token
        )
        XCTAssertEqual(incapableDispatch, .unavailable)
        XCTAssertTrue(incapablePlatform.postedPIDs.isEmpty)

        let unavailableIdentity = TargetIdentityFake()
        let unavailablePlatform = TargetSystemPlatformFake(
            focus: .target(
                TargetFocusReference(pid: 8484, opaqueIdentity: unavailableIdentity)
            )
        )
        let unavailableTracker = TargetTracker(clock: StaticClock(), platform: unavailablePlatform)
        guard case let .external(unavailableID) = await unavailableTracker.snapshotTarget() else {
            return XCTFail("unavailable fixture target was not captured")
        }
        unavailablePlatform.focus = .unavailable
        let unavailableDispatch = await unavailableTracker.revalidateAndDispatch(
            targetID: unavailableID,
            token: token
        )
        XCTAssertEqual(unavailableDispatch, .unavailable)
        XCTAssertTrue(unavailablePlatform.postedPIDs.isEmpty)

        let lifecyclePlatform = TargetSystemPlatformFake(focus: .none)
        weak var releasedTracker: TargetTracker?
        do {
            var lifecycleTracker: TargetTracker? = TargetTracker(
                clock: StaticClock(),
                platform: lifecyclePlatform
            )
            releasedTracker = lifecycleTracker
            lifecycleTracker = nil
        }
        XCTAssertNil(releasedTracker)
        for _ in 0..<20 where lifecyclePlatform.tearDownCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(lifecyclePlatform.tearDownCount, 1)

        _ = TargetTracker(clock: StaticClock())
    }

    @MainActor
    func testTargetTrackerPrimesExternalFocusBeforeMenuInteraction() async {
        let identity = TargetIdentityFake()
        let platform = TargetSystemPlatformFake(
            focus: .target(
                TargetFocusReference(pid: 9191, opaqueIdentity: identity)
            )
        )
        let tracker = TargetTracker(clock: StaticClock(), platform: platform)

        platform.focus = .ownApplication
        guard case let .external(targetID) = await tracker.snapshotTarget() else {
            return XCTFail("the external focus visible before the menu opened was not retained")
        }

        platform.focus = .target(
            TargetFocusReference(pid: 9191, opaqueIdentity: identity)
        )
        let token = effectToken(generation: 92)
        let validation = await tracker.validate(targetID: targetID, token: token)
        let dispatch = await tracker.revalidateAndDispatch(targetID: targetID, token: token)
        XCTAssertEqual(validation, .valid)
        XCTAssertEqual(dispatch, .dispatched)
        XCTAssertEqual(platform.postedPIDs, [9191, 9191])
    }

    func testCapturedTargetIDAndFullTokenReachStableDispatch() async {
        let target = TargetFake()
        let fixture = makeFixture(target: target)
        let token = effectToken(generation: 44)

        let outcome = await fixture.coordinator.deliver(
            text: "result",
            to: .external(target.id),
            preference: .automaticPaste,
            token: token
        )

        XCTAssertEqual(outcome, .pasteEventDispatched)
        let validatedIDs = await target.validatedIDs()
        let dispatchedIDs = await target.dispatchedIDs()
        let tokens = await target.tokens()
        let eventPosts = await target.eventPostCount()
        XCTAssertEqual(validatedIDs, [target.id])
        XCTAssertEqual(dispatchedIDs, [target.id])
        XCTAssertEqual(tokens, [token, token])
        XCTAssertEqual(eventPosts, 2)
    }
}

private struct DeliveryFixture {
    let coordinator: DeliveryCoordinator
    let pasteboard: PasteboardFake
    let target: TargetFake
    let sink: OnboardingSinkFake
}

private func makeFixture(
    pasteboard: PasteboardFake = PasteboardFake(),
    target: TargetFake = TargetFake(),
    sink: OnboardingSinkFake = OnboardingSinkFake(),
    clock: any AppClock = StaticClock()
) -> DeliveryFixture {
    DeliveryFixture(
        coordinator: DeliveryCoordinator(
            pasteboard: pasteboard,
            target: target,
            onboardingSink: sink,
            clock: clock,
            settleDelay: .milliseconds(250)
        ),
        pasteboard: pasteboard,
        target: target,
        sink: sink
    )
}

private func effectToken(generation: UInt64 = 1) -> EffectToken {
    EffectToken(sessionID: SessionID(), generation: generation)
}

private struct OnboardingDelivery: Equatable, Sendable {
    let sessionID: SessionID
    let text: String
}

private actor OnboardingSinkFake: OnboardingTestSink {
    private var deliveries: [OnboardingDelivery] = []

    func deliver(_ text: String, sessionID: SessionID) {
        deliveries.append(OnboardingDelivery(sessionID: sessionID, text: text))
    }

    func values() -> AsyncStream<(SessionID, String)> {
        AsyncStream { continuation in continuation.finish() }
    }

    func recorded() -> [OnboardingDelivery] { deliveries }
}

private struct PasteboardStats: Equatable, Sendable {
    var captures = 0
    var directWrites = 0
    var compareWrites = 0
    var restoreAttempts = 0
    var restores = 0
    var userCopies = 0
}

private struct PasteboardState: Equatable, Sendable {
    let items: [PasteboardItemSnapshot]
    let changeCount: Int
}

private actor PasteboardFake: PasteboardAccess {
    private var items: [PasteboardItemSnapshot]
    private var count: Int
    private let captureOverride: PasteboardCaptureResult?
    private let changeBeforeCompare: String?
    private let directWriteSucceeds: Bool
    private let directGate: AsyncGate?
    private let compareGate: AsyncGate?
    private var statistics = PasteboardStats()

    init(
        text: String = "original",
        changeCount: Int = 1,
        captureOverride: PasteboardCaptureResult? = nil,
        changeBeforeCompare: String? = nil,
        directWriteSucceeds: Bool = true,
        directGate: AsyncGate? = nil,
        compareGate: AsyncGate? = nil
    ) {
        items = [Self.textItem(text)]
        count = changeCount
        self.captureOverride = captureOverride
        self.changeBeforeCompare = changeBeforeCompare
        self.directWriteSucceeds = directWriteSucceeds
        self.directGate = directGate
        self.compareGate = compareGate
    }

    func capture() -> PasteboardCaptureResult {
        statistics.captures += 1
        return captureOverride ?? .captured(PasteboardSnapshot(items: items, changeCount: count))
    }

    func replaceText(_ text: String) async -> Bool {
        statistics.directWrites += 1
        if let directGate { await directGate.wait() }
        guard !Task.isCancelled else { return false }
        guard directWriteSucceeds else { return false }
        items = [Self.textItem(text)]
        count += 1
        return true
    }

    func compareAndWrite(
        text: String,
        expectedChangeCount: Int
    ) async -> PasteboardWriteResult {
        statistics.compareWrites += 1
        if let compareGate { await compareGate.wait() }
        guard !Task.isCancelled else { return .failed }
        if let changeBeforeCompare {
            userCopy(changeBeforeCompare)
        }
        guard count == expectedChangeCount else { return .changed }
        items = [Self.textItem(text)]
        count += 1
        return .written(ownedChangeCount: count)
    }

    func guardedRestore(
        _ snapshot: PasteboardSnapshot,
        ownedChangeCount: Int
    ) -> Bool {
        statistics.restoreAttempts += 1
        guard count == ownedChangeCount else { return false }
        items = snapshot.items
        count += 1
        statistics.restores += 1
        return true
    }

    func userCopy(_ text: String) {
        items = [Self.textItem(text)]
        count += 1
        statistics.userCopies += 1
    }

    func currentText() -> String? {
        guard let data = items.first?.representations.first?.data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func state() -> PasteboardState { PasteboardState(items: items, changeCount: count) }
    func stats() -> PasteboardStats { statistics }
    func changeCount() -> Int { count }

    fileprivate static func textItem(_ text: String) -> PasteboardItemSnapshot {
        PasteboardItemSnapshot(
            representations: [
                PasteboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))
            ]
        )
    }
}

private struct TargetStats: Equatable, Sendable {
    var validations = 0
    var dispatchAttempts = 0
    var eventPosts = 0
}

private actor TargetFake: TargetValidating {
    let id: DeliveryTargetID
    private var validationResults: [TargetValidation]
    private var dispatchResults: [TargetDispatch]
    private let dispatchGate: AsyncGate?
    private var statistics = TargetStats()
    private var validationIDs: [DeliveryTargetID] = []
    private var dispatchIDs: [DeliveryTargetID] = []
    private var seenTokens: [EffectToken] = []

    init(
        id: DeliveryTargetID = DeliveryTargetID(),
        validations: [TargetValidation] = [.valid],
        dispatches: [TargetDispatch] = [.dispatched],
        dispatchGate: AsyncGate? = nil
    ) {
        self.id = id
        validationResults = validations
        dispatchResults = dispatches
        self.dispatchGate = dispatchGate
    }

    func validate(targetID: DeliveryTargetID, token: EffectToken) -> TargetValidation {
        statistics.validations += 1
        validationIDs.append(targetID)
        seenTokens.append(token)
        return validationResults.isEmpty ? .valid : validationResults.removeFirst()
    }

    func revalidateAndDispatch(
        targetID: DeliveryTargetID,
        token: EffectToken
    ) async -> TargetDispatch {
        statistics.dispatchAttempts += 1
        dispatchIDs.append(targetID)
        seenTokens.append(token)
        if let dispatchGate { await dispatchGate.wait() }
        guard !Task.isCancelled else { return .changed }
        let result = dispatchResults.isEmpty ? .dispatched : dispatchResults.removeFirst()
        if result == .dispatched { statistics.eventPosts += 2 }
        return result
    }

    func stats() -> TargetStats { statistics }
    func eventPostCount() -> Int { statistics.eventPosts }
    func validatedIDs() -> [DeliveryTargetID] { validationIDs }
    func dispatchedIDs() -> [DeliveryTargetID] { dispatchIDs }
    func tokens() -> [EffectToken] { seenTokens }
}

private actor AsyncGate {
    private var entered = false
    private var openState = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pending = entryWaiters
        entryWaiters.removeAll()
        pending.forEach { $0.resume() }
        guard !openState else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        openState = true
        let pending = openWaiters
        openWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct StaticClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func sleep(for duration: Duration) async throws {}
}

private struct GateClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let gate: AsyncGate

    func sleep(for duration: Duration) async throws {
        await gate.wait()
        try Task.checkCancellation()
    }
}

private final class MutableClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { lock.withLock { value } }

    func sleep(for duration: Duration) async throws {}

    func advance(by seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

@MainActor
private final class PasteboardPlatformFake: PasteboardPlatform {
    private var count = 1
    private let storedData: Data?
    private let changeCountAfterRead: Int?
    private let onRead: (() -> Void)?

    init(
        data: Data?,
        changeCountAfterRead: Int? = nil,
        onRead: (() -> Void)? = nil
    ) {
        storedData = data
        self.changeCountAfterRead = changeCountAfterRead
        self.onRead = onRead
    }

    var changeCount: Int { count }
    var itemCount: Int? { 1 }
    func types(at index: Int) -> [String]? { ["public.test"] }

    func data(at itemIndex: Int, type: String) -> Data? {
        onRead?()
        if let changeCountAfterRead { count = changeCountAfterRead }
        return storedData
    }

    func replaceText(_ text: String) -> Bool { true }
    func restore(_ items: [PasteboardItemSnapshot]) -> Bool { true }
}

@MainActor
private final class OrderedPasteboardPlatformFake: PasteboardPlatform {
    var items: [PasteboardItemSnapshot]
    private(set) var changeCount: Int

    init(items: [PasteboardItemSnapshot], changeCount: Int) {
        self.items = items
        self.changeCount = changeCount
    }

    var itemCount: Int? { items.count }

    func types(at index: Int) -> [String]? {
        guard items.indices.contains(index) else { return nil }
        return items[index].representations.map(\.type)
    }

    func data(at itemIndex: Int, type: String) -> Data? {
        guard items.indices.contains(itemIndex) else { return nil }
        return items[itemIndex].representations.first(where: { $0.type == type })?.data
    }

    func replaceText(_ text: String) -> Bool {
        items = [
            PasteboardItemSnapshot(
                representations: [
                    PasteboardRepresentation(
                        type: "public.utf8-plain-text",
                        data: Data(text.utf8)
                    )
                ]
            )
        ]
        changeCount += 1
        return true
    }

    func restore(_ items: [PasteboardItemSnapshot]) -> Bool {
        self.items = items
        changeCount += 1
        return true
    }
}

@MainActor
private final class TargetIdentityFake {
    let process: UUID
    let window: UUID
    let element: UUID
    let editable: Bool
    let alive: Bool

    init(
        process: UUID = UUID(),
        window: UUID = UUID(),
        element: UUID = UUID(),
        editable: Bool = true,
        alive: Bool = true
    ) {
        self.process = process
        self.window = window
        self.element = element
        self.editable = editable
        self.alive = alive
    }

    func copy(
        process: UUID? = nil,
        window: UUID? = nil,
        element: UUID? = nil,
        editable: Bool? = nil,
        alive: Bool? = nil
    ) -> TargetIdentityFake {
        TargetIdentityFake(
            process: process ?? self.process,
            window: window ?? self.window,
            element: element ?? self.element,
            editable: editable ?? self.editable,
            alive: alive ?? self.alive
        )
    }
}

@MainActor
private final class TargetSystemPlatformFake: TargetSystemPlatform {
    var focus: TargetFocusLookup
    var postingAvailable: Bool
    private var handler: (@MainActor @Sendable () -> Void)?
    private(set) var postedPIDs: [pid_t] = []
    private(set) var seenTokens: [EffectToken] = []
    private(set) var tearDownCount = 0

    init(focus: TargetFocusLookup, postingAvailable: Bool = true) {
        self.focus = focus
        self.postingAvailable = postingAvailable
    }

    func installChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    func currentFocus() -> TargetFocusLookup { focus }

    func canPostProcessAddressedEvents() -> Bool { postingAvailable }

    func sameTarget(_ captured: TargetFocusReference, _ live: TargetFocusReference) -> Bool {
        guard let capturedIdentity = captured.opaqueIdentity as? TargetIdentityFake,
              let liveIdentity = live.opaqueIdentity as? TargetIdentityFake
        else {
            return false
        }
        return captured.pid == live.pid
            && capturedIdentity.process == liveIdentity.process
            && capturedIdentity.window == liveIdentity.window
            && capturedIdentity.element == liveIdentity.element
            && capturedIdentity.editable
            && liveIdentity.editable
            && capturedIdentity.alive
            && liveIdentity.alive
    }

    func postCommandV(to target: TargetFocusReference, token: EffectToken) -> Bool {
        guard !Task.isCancelled, postingAvailable else { return false }
        postedPIDs.append(target.pid)
        postedPIDs.append(target.pid)
        seenTokens.append(token)
        return true
    }

    func emitChange() {
        handler?()
    }

    func tearDown() {
        tearDownCount += 1
        handler = nil
    }
}
