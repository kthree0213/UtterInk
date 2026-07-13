import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class AppModelContractTests: XCTestCase {
    private enum FixtureError: Error {
        case unavailable
    }

    func testAppModelBootstrapsAndForwardsStartWithoutOwningRecordingFlag() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)

        await model.bootstrap()
        model.startOrStop()

        XCTAssertEqual(controller.bootstrapCount, 1)
        XCTAssertEqual(controller.intents, [.start(.focusedExternal)])
        XCTAssertFalse(
            Mirror(reflecting: model).children.contains { $0.label == "isRecording" }
        )
    }

    func testAppModelRejectsIntentsUntilBootstrapCompletes() async {
        let gate = AppBootstrapGate()
        let controller = RecordingIntentControllerSpy()
        controller.bootstrapGate = gate
        let model = AppModel(controller: controller)

        model.startOrStop()
        let bootstrap = Task { await model.bootstrap() }
        await waitUntil { controller.bootstrapCount == 1 }
        model.startOrStop()

        XCTAssertTrue(controller.intents.isEmpty)
        XCTAssertEqual(model.readiness, .pending)

        await gate.open()
        await bootstrap.value
        model.startOrStop()

        XCTAssertEqual(controller.intents, [.start(.focusedExternal)])
        XCTAssertEqual(model.readiness, .ready)
    }

    func testBootstrapIsSingleFlightAndIdempotent() async {
        let gate = AppBootstrapGate()
        let controller = RecordingIntentControllerSpy()
        controller.bootstrapGate = gate
        let model = AppModel(controller: controller)

        let first = Task { await model.bootstrap() }
        await waitUntil { controller.bootstrapCount == 1 }
        let second = Task { await model.bootstrap() }
        await Task.yield()

        XCTAssertEqual(controller.bootstrapCount, 1)

        await gate.open()
        await first.value
        await second.value
        await model.bootstrap()

        XCTAssertEqual(controller.bootstrapCount, 1)
    }

    func testFailedPostBootstrapVerificationKeepsIntentsAndHotkeyDisabled() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(
            controller: controller,
            postBootstrapVerification: { throw FixtureError.unavailable }
        )
        let hotkey = AppHotkeyFake()
        let composition = AppComposition(
            model: model,
            features: featureDependencies(hotkey: hotkey)
        )

        await composition.start()
        model.startOrStop()

        XCTAssertEqual(controller.bootstrapCount, 1)
        XCTAssertEqual(model.readiness, .failed)
        XCTAssertTrue(controller.intents.isEmpty)
        XCTAssertTrue(hotkey.calls.isEmpty)
    }

    func testStartOrStopMapsOnlyValidPipelineStages() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()

        controller.state = pipelineState(stage: .recording)
        model.startOrStop()
        controller.state = pipelineState(stage: .transcribing)
        model.startOrStop()
        controller.state = pipelineState(stage: .failed)
        model.startOrStop()
        model.cancel()

        XCTAssertEqual(
            controller.intents,
            [.stop, .start(.focusedExternal), .cancel]
        )
    }

    func testToggleHotkeyResolvesEveryPressAgainstAuthoritativePipelineStage() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()

        // Two idle presses model a service latch that advanced after a rejected
        // start. Neither press is allowed to become a dead Stop intent.
        controller.state = pipelineState(stage: .idle)
        model.handleToggleHotkey()
        model.handleToggleHotkey()
        controller.state = pipelineState(stage: .requestingPermission)
        model.handleToggleHotkey()
        controller.state = pipelineState(stage: .recording)
        model.handleToggleHotkey()
        for stage in [
            PipelineStage.stopping,
            .transcribing,
            .polishing,
            .delivering,
        ] {
            controller.state = pipelineState(stage: stage)
            model.handleToggleHotkey()
        }
        controller.state = pipelineState(stage: .completed)
        model.handleToggleHotkey()

        XCTAssertEqual(
            controller.intents,
            [
                .start(.focusedExternal),
                .start(.focusedExternal),
                .cancel,
                .stop,
                .start(.focusedExternal),
            ]
        )
    }

    func testHoldReleaseCancelsPendingOrActiveStartAndStopsRecording() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()

        controller.state = pipelineState(stage: .idle)
        model.releaseHoldToTalk()
        controller.state = pipelineState(stage: .requestingPermission)
        model.releaseHoldToTalk()
        controller.state = pipelineState(stage: .recording)
        model.releaseHoldToTalk()
        for stage in [
            PipelineStage.stopping,
            .transcribing,
            .polishing,
            .delivering,
        ] {
            controller.state = pipelineState(stage: stage)
            model.releaseHoldToTalk()
        }
        controller.state = pipelineState(stage: .completed)
        model.releaseHoldToTalk()

        XCTAssertEqual(controller.intents, [.cancel, .cancel, .stop])
    }

    func testEscapeCancelsActiveStagesAndAcknowledgesTerminalStages() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()

        let activeStages: [PipelineStage] = [
            .requestingPermission,
            .recording,
            .stopping,
            .transcribing,
            .polishing,
            .delivering,
        ]
        for stage in activeStages {
            controller.state = pipelineState(stage: stage)
            model.performEscape()
        }
        controller.state = pipelineState(stage: .completed)
        model.performEscape()
        controller.state = pipelineState(stage: .failed)
        model.performEscape()
        controller.state = pipelineState(stage: .idle)
        model.performEscape()

        XCTAssertEqual(
            controller.intents,
            Array(repeating: .cancel, count: activeStages.count)
                + [.acknowledge, .acknowledge, .cancel]
        )
    }

    func testLatestResultRecoveryUsesTypedControllerIntents() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()
        let olderID = SessionID()
        let latestID = SessionID()
        controller.volatileResults = [
            DictationResult(
                sessionID: olderID,
                startedAt: Date(timeIntervalSince1970: 1),
                rawText: "older",
                finalText: "older",
                source: .raw,
                warning: nil,
                delivery: nil
            ),
            DictationResult(
                sessionID: latestID,
                startedAt: Date(timeIntervalSince1970: 2),
                rawText: "latest",
                finalText: "latest",
                source: .raw,
                warning: nil,
                delivery: nil
            ),
        ]

        XCTAssertEqual(model.latestResult?.sessionID, latestID)
        model.copyResult(latestID)
        model.pasteAgain(latestID)
        model.acknowledge()

        XCTAssertEqual(
            controller.intents,
            [.copyResult(latestID), .pasteAgain(latestID), .acknowledge]
        )
    }

    func testLatestResultDoesNotRegressToAnOlderVolatileRecoveryAction() async {
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        await model.bootstrap()
        let oldID = SessionID()
        let currentID = SessionID()
        controller.volatileResults = [
            DictationResult(
                sessionID: oldID,
                startedAt: Date(timeIntervalSince1970: 1),
                rawText: "old",
                finalText: "old",
                source: .raw,
                warning: nil,
                delivery: .copiedByUser
            ),
        ]
        controller.historyRecords = [
            HistoryRecord(
                sessionID: currentID,
                startedAt: Date(timeIntervalSince1970: 2),
                rawText: "current",
                finalText: "current",
                source: .raw,
                warning: nil,
                delivery: .pasteEventDispatched,
                outcome: .delivered
            ),
        ]

        XCTAssertEqual(model.latestResult?.sessionID, currentID)
        XCTAssertEqual(model.latestResult?.finalText, "current")
    }

    func testCompositionArmsHotkeyOnlyAfterSharedModelIsReady() async {
        let gate = AppBootstrapGate()
        let controller = RecordingIntentControllerSpy()
        controller.bootstrapGate = gate
        let model = AppModel(controller: controller)
        let hotkey = AppHotkeyFake()
        let composition = AppComposition(
            model: model,
            features: featureDependencies(hotkey: hotkey)
        )

        let first = Task { await composition.start() }
        await waitUntil { controller.bootstrapCount == 1 }
        let second = Task { await composition.start() }
        await Task.yield()

        XCTAssertTrue(hotkey.calls.isEmpty)

        await gate.open()
        await first.value
        await second.value

        XCTAssertEqual(hotkey.calls, ["hotkey.arm"])
        XCTAssertTrue(composition.model === model)
    }

    func testCompositionUsesOneHotkeyArmWhenConcurrentStartsSuspend() async {
        let armGate = AppBootstrapGate()
        let controller = RecordingIntentControllerSpy()
        let model = AppModel(controller: controller)
        let hotkey = AppHotkeyFake()
        hotkey.armGate = armGate
        let composition = AppComposition(
            model: model,
            features: featureDependencies(hotkey: hotkey)
        )

        let first = Task { await composition.start() }
        await waitUntil { hotkey.calls == ["hotkey.arm"] }
        let second = Task { await composition.start() }
        await Task.yield()

        XCTAssertEqual(hotkey.calls, ["hotkey.arm"])

        await armGate.open()
        await first.value
        await second.value

        XCTAssertEqual(hotkey.calls, ["hotkey.arm"])
    }

    func testHostedUnitTestsDoNotConstructTheLiveComposition() {
        XCTAssertFalse(UtterInkApp().usesLiveComposition)
    }

    func testAppConstructionFailureUsesUnavailableModelWithoutStartingServices() {
        var factoryCallCount = 0
        let app = UtterInkApp(
            isHostedUnitTest: false,
            compositionFactory: {
                factoryCallCount += 1
                throw FixtureError.unavailable
            }
        )

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertFalse(app.usesLiveComposition)
        XCTAssertEqual(app.readinessForTests, .failed)
    }

    func testFeatureDependencyWiringUsesProtocolFakes() {
        let hotkey = AppHotkeyFake()
        let dependencies = featureDependencies(hotkey: hotkey)

        XCTAssertTrue(dependencies.settings is AppSettingsFake)
        XCTAssertTrue(dependencies.permissions is AppPermissionFake)
        XCTAssertTrue(dependencies.systemSettings is AppSystemSettingsFake)
        XCTAssertTrue(dependencies.launchAtLogin is AppLaunchAtLoginFake)
        XCTAssertTrue(dependencies.hotkeyProbe === hotkey)
        XCTAssertTrue(dependencies.hotkeyConfiguration === hotkey)
        XCTAssertTrue(dependencies.credentials is AppCredentialFake)
        XCTAssertTrue(dependencies.credentialMigration is AppCredentialMigrationFake)
        XCTAssertTrue(dependencies.providerValidation is AppProviderValidationFake)
        XCTAssertTrue(dependencies.diagnosticsExport is AppDiagnosticsExportFake)
        XCTAssertTrue(dependencies.onboardingSink is AppOnboardingSinkFake)
        XCTAssertTrue(dependencies.clock is AppClockFake)
    }

    private func featureDependencies(hotkey: AppHotkeyFake) -> AppFeatureDependencies {
        AppFeatureDependencies(
            settings: AppSettingsFake(),
            permissions: AppPermissionFake(),
            systemSettings: AppSystemSettingsFake(),
            launchAtLogin: AppLaunchAtLoginFake(),
            hotkeyProbe: hotkey,
            hotkeyConfiguration: hotkey,
            credentials: AppCredentialFake(),
            credentialMigration: AppCredentialMigrationFake(),
            providerValidation: AppProviderValidationFake(),
            diagnosticsExport: AppDiagnosticsExportFake(),
            onboardingSink: AppOnboardingSinkFake(),
            clock: AppClockFake()
        )
    }

    private func pipelineState(stage: PipelineStage) -> PipelineState {
        PipelineState(
            stage: stage,
            sessionID: nil,
            token: nil,
            result: nil,
            failure: nil
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<100 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}
