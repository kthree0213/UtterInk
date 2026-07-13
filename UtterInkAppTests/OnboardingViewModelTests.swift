import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    func testFlowHasFourExactSteps() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.title),
            ["Privacy", "Readiness", "Shortcut Test", "Test Dictation"]
        )
    }

    func testClosingDoesNotCompleteOnboarding() async throws {
        let harness = OnboardingHarness()
        harness.model.go(to: .shortcutTest)

        await harness.model.close()

        let settings = try await harness.settings.current()
        let updateCalls = await harness.settings.recordedCalls()
            .filter { $0 == "settings.update" }
        XCTAssertFalse(settings.onboardingCompletedV2)
        XCTAssertEqual(settings.onboardingStep, OnboardingStep.shortcutTest.rawValue)
        XCTAssertEqual(updateCalls, ["settings.update"])
    }

    func testClosingNeverCancelsAnUnrelatedActiveSession() async throws {
        let harness = OnboardingHarness()
        harness.controller.state = PipelineState(
            stage: .recording,
            sessionID: SessionID(),
            token: nil,
            result: nil,
            failure: nil
        )

        await harness.model.close()

        XCTAssertEqual(harness.controller.intents, [])
        let settings = try await harness.settings.current()
        XCTAssertFalse(settings.onboardingCompletedV2)
    }

    func testEmptyCancelledAndFailedResultsDoNotComplete() async throws {
        let harness = OnboardingHarness()

        await harness.model.handleRecoverableResult(nil)
        await harness.model.handleRecoverableResult(.fixture(finalText: ""))
        await harness.model.handleRecoverableResult(.fixture(finalText: " \n\t "))

        let settings = try await harness.settings.current()
        XCTAssertFalse(settings.onboardingCompletedV2)
        XCTAssertNil(harness.model.recoverableResult)
    }

    func testRecoverableRawOrPolishedResultCompletes() async throws {
        for result in [
            DictationResult.fixture(finalText: "non-empty"),
            DictationResult.fixture(finalText: " polished ", source: .polished),
        ] {
            let harness = OnboardingHarness()

            await harness.model.handleRecoverableResult(result)

            let settings = try await harness.settings.current()
            let updateCalls = await harness.settings.recordedCalls()
                .filter { $0 == "settings.update" }
            XCTAssertTrue(settings.onboardingCompletedV2)
            XCTAssertEqual(harness.model.recoverableResult?.sessionID, result.sessionID)
            XCTAssertEqual(updateCalls, ["settings.update"])
        }
    }

    func testHistoryChoiceIsSavedBeforeOnboardingStartIntent() async throws {
        let harness = OnboardingHarness()

        await harness.model.setHistoryEnabled(false)
        await harness.model.startTestDictation()

        let settings = try await harness.settings.current()
        let updateCalls = await harness.settings.recordedCalls()
            .filter { $0 == "settings.update" }
        XCTAssertFalse(settings.historyEnabled)
        XCTAssertEqual(
            harness.controller.intents,
            [.setHistoryEnabled(false), .start(.onboardingTest)]
        )
        XCTAssertEqual(updateCalls, ["settings.update"])
    }

    func testOnboardingStartWaitsForAtomicHistoryChangeToSettle() async {
        let harness = OnboardingHarness()
        let gate = AppBootstrapGate()
        await harness.settings.setUpdateGate(gate)

        let historyChange = Task { await harness.model.setHistoryEnabled(false) }
        await gate.waitUntilEntered()
        let start = Task { await harness.model.startTestDictation() }
        await Task.yield()

        XCTAssertEqual(harness.controller.intents, [.setHistoryEnabled(false)])

        await gate.open()
        await historyChange.value
        await start.value
        XCTAssertEqual(
            harness.controller.intents,
            [.setHistoryEnabled(false), .start(.onboardingTest)]
        )
    }

    func testFailedHistorySavePreventsOnboardingStart() async {
        let harness = OnboardingHarness()
        await harness.settings.setSaveFailureEnabled(true)

        await harness.model.setHistoryEnabled(false)
        await harness.model.startTestDictation()

        XCTAssertEqual(harness.controller.intents, [.setHistoryEnabled(false)])
        XCTAssertNotNil(harness.model.failureMessage)
    }

    func testShortcutProbeCompletesInPlaceWithoutOpeningSettings() async {
        let harness = OnboardingHarness()

        await harness.model.armShortcutProbe()
        await harness.hotkeyProbe.emitConfiguredShortcut()
        await harness.waitUntil { harness.model.shortcutTestPassed }

        XCTAssertTrue(harness.model.shortcutTestPassed)
        XCTAssertEqual(harness.systemSettings.openCount, 0)
        XCTAssertEqual(harness.hotkeyProbe.calls, ["hotkey.armProbeOnly"])
    }

    func testFinishedShortcutProbeCanBeRearmed() async {
        let harness = OnboardingHarness()

        await harness.model.armShortcutProbe()
        harness.hotkeyProbe.finishProbe()
        await harness.waitUntil { !harness.model.isShortcutProbeArmed }
        await harness.model.armShortcutProbe()

        XCTAssertTrue(harness.model.isShortcutProbeArmed)
        XCTAssertEqual(
            harness.hotkeyProbe.calls,
            ["hotkey.armProbeOnly", "hotkey.armProbeOnly"]
        )
    }

    func testPrivacyCopyIsExactAndNamesOnlyConditionalTranscriptEgress() async {
        var settings = UserSettings.p0Default
        let profile = ProviderProfile(
            id: UUID(),
            title: "Example",
            baseURL: URL(string: "https://api.example.test/v1")!,
            modelID: "model",
            policy: .remoteHTTPS
        )
        settings.providerProfiles = [profile]
        settings.selectedProviderProfileID = profile.id
        let harness = OnboardingHarness(settingsValue: settings)

        await harness.model.load()

        XCTAssertEqual(
            harness.model.audioPrivacyText,
            "Audio is processed locally on this Mac and is not retained."
        )
        XCTAssertEqual(
            harness.model.historyPrivacyText,
            "History stores raw and final transcript text locally on this Mac only when enabled."
        )
        XCTAssertEqual(
            harness.model.remoteTextPrivacyText,
            "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to api.example.test."
        )
    }

    func testPrivacyDisclosureIncludesNormalizedNonDefaultPort() async {
        var settings = UserSettings.p0Default
        let profile = ProviderProfile(
            id: UUID(),
            title: "Private Gateway",
            baseURL: URL(string: "https://API.EXAMPLE.TEST:8443/v1")!,
            modelID: "model",
            policy: .remoteHTTPS
        )
        settings.providerProfiles = [profile]
        settings.selectedProviderProfileID = profile.id
        let harness = OnboardingHarness(settingsValue: settings)

        await harness.model.load()

        XCTAssertEqual(
            harness.model.remoteTextPrivacyText,
            "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to api.example.test:8443."
        )
    }

    func testHistoryToggleLoadsEffectiveControllerStateAfterPartialFailure() async {
        let harness = OnboardingHarness()
        harness.controller.historyControlStatus = .failed(
            enabled: false,
            failure: .preferenceSaveFailed
        )

        await harness.model.load()

        XCTAssertFalse(harness.model.historyEnabled)
    }

    func testReadinessReflectsTypedPermissionAndModelStates() async {
        let harness = OnboardingHarness()
        await harness.permissions.setMicrophone(.denied)
        await harness.permissions.setAccessibility(.denied)
        harness.controller.speechModelState = .downloading(modelID: "small", progress: 0.25)

        await harness.model.refreshReadiness()

        XCTAssertEqual(harness.model.microphonePermission, .denied)
        XCTAssertEqual(harness.model.accessibilityPermission, .denied)
        XCTAssertFalse(harness.model.canStartTestDictation)
        XCTAssertEqual(harness.model.modelProgress, 0.25)
        XCTAssertEqual(
            harness.model.accessibilityExplanation,
            "Without Accessibility, local transcription and explicit Copy still work; global shortcuts and automatic paste are limited."
        )

        harness.controller.speechModelState = .ready(modelID: "base")
        await harness.model.refreshReadiness()
        XCTAssertFalse(harness.model.canStartTestDictation)

        await harness.permissions.setMicrophone(.granted)
        harness.controller.speechModelState = .ready(modelID: "small")
        await harness.model.refreshReadiness()
        XCTAssertTrue(harness.model.canStartTestDictation)
    }

    func testUndeterminedMicrophoneCanRequestOnStartWhileDeniedIsBlocked() async {
        let firstRun = OnboardingHarness()
        await firstRun.permissions.setMicrophone(.notDetermined)
        await firstRun.model.refreshReadiness()

        await firstRun.model.startTestDictation()

        XCTAssertEqual(firstRun.controller.intents, [.start(.onboardingTest)])
        await firstRun.model.close()

        let denied = OnboardingHarness()
        await denied.permissions.setMicrophone(.denied)
        await denied.model.refreshReadiness()

        await denied.model.startTestDictation()

        XCTAssertEqual(denied.controller.intents, [])
        XCTAssertNotNil(denied.model.failureMessage)
    }

    func testRecognitionAndModelSelectionsUseAtomicUpdates() async throws {
        let harness = OnboardingHarness()

        await harness.model.setRecognition(.fixed(languageCode: "en"))
        await harness.model.selectSpeechModel("base")

        let settings = try await harness.settings.current()
        let updateCallCount = await harness.settings.recordedCalls()
            .filter { $0 == "settings.update" }.count
        XCTAssertEqual(settings.recognition, .fixed(languageCode: "en"))
        XCTAssertEqual(settings.speechModelID, "base")
        XCTAssertEqual(harness.controller.preparedSpeechModelIDs, ["base"])
        XCTAssertEqual(updateCallCount, 2)
    }

    func testSharedSinkPublishesRecoverableRawResultAndCompletes() async throws {
        let harness = OnboardingHarness()
        let result = DictationResult.fixture(finalText: "polished", source: .polished)
        harness.controller.volatileResults = [result]

        await harness.model.startTestDictation()
        let initialSinkCalls = await harness.onboardingSink.recordedCalls()
        XCTAssertEqual(initialSinkCalls, ["onboarding.values"])
        XCTAssertEqual(harness.controller.intents, [.start(.onboardingTest)])
        await harness.onboardingSink.deliver("polished", sessionID: result.sessionID)
        await harness.waitUntil { harness.model.recoverableResult != nil }

        XCTAssertEqual(harness.model.displayedRawText, "raw")
        let settings = try await harness.settings.current()
        let sinkCalls = await harness.onboardingSink.recordedCalls()
        XCTAssertTrue(settings.onboardingCompletedV2)
        XCTAssertEqual(sinkCalls, ["onboarding.values", "onboarding.deliver"])
    }

    func testCopyUsesTypedRecoveryIntentAndBuiltInPasteFieldStaysInternal() async {
        let harness = OnboardingHarness()
        let result = DictationResult.fixture(finalText: "result")
        await harness.model.handleRecoverableResult(result)

        harness.model.copyResult()
        harness.model.testPasteText = "result"

        XCTAssertEqual(harness.controller.intents, [.copyResult(result.sessionID)])
        XCTAssertEqual(harness.model.testPasteText, "result")
        XCTAssertEqual(harness.systemSettings.openCount, 0)
    }
}
