import XCTest
import UtterInkCore
@testable import UtterInk

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testEnglishOnlyBaselineAndTypedRoutesIncludeFutureDestinations() {
        XCTAssertEqual(SettingsRootModel.supportedInterfaceLanguages, ["English"])
        XCTAssertEqual(
            SettingsRoute.allCases,
            [
                .general,
                .permissions,
                .recognitionLanguage,
                .speechModel,
                .shortcuts,
                .outputModes,
                .provider,
                .diagnostics,
            ]
        )
        XCTAssertFalse(SettingsRoute.speechModel.isPlaceholder)
        XCTAssertFalse(SettingsRoute.outputModes.isPlaceholder)
        XCTAssertFalse(SettingsRoute.provider.isPlaceholder)
        XCTAssertFalse(SettingsRoute.diagnostics.isPlaceholder)
    }

    func testGeneralOrdinaryValuesPublishOnlyAfterSuccessfulRoundTrip() async throws {
        var initial = UserSettings.p0Default
        initial.launchAtLogin = false
        initial.showFloatingRecorder = true
        let store = AppSettingsFake(value: initial)
        let controller = RecordingIntentControllerSpy()
        let launch = AppLaunchAtLoginFake()
        var floatingValues: [Bool] = []
        let model = GeneralSettingsViewModel(
            settings: store,
            controller: controller,
            launchAtLogin: launch,
            setFloatingRecorderEnabled: { floatingValues.append($0) }
        )

        await model.load()
        await model.setFloatingRecorderEnabled(false)
        let savedFloating = try await store.current().showFloatingRecorder

        XCTAssertFalse(model.showFloatingRecorder)
        XCTAssertFalse(savedFloating)
        XCTAssertEqual(floatingValues, [false])
        XCTAssertNil(model.failureMessage)

        await store.setSaveFailureEnabled(true)
        await model.setFloatingRecorderEnabled(true)

        XCTAssertFalse(model.showFloatingRecorder)
        XCTAssertEqual(floatingValues, [false])
        XCTAssertNotNil(model.failureMessage)
        XCTAssertEqual(model.failureSymbol, "exclamationmark.triangle.fill")
    }

    func testOrdinaryFailurePathsKeepPublishedValuesAndDelaySideEffects() async throws {
        let deliveryStore = AppSettingsFake()
        let delivery = GeneralSettingsViewModel(
            settings: deliveryStore,
            controller: RecordingIntentControllerSpy(),
            launchAtLogin: AppLaunchAtLoginFake()
        )
        await delivery.load()
        await deliveryStore.setSaveFailureEnabled(true)
        await delivery.setDeliveryPreference(.copyOnly)
        XCTAssertEqual(delivery.deliveryPreference, .automaticPaste)
        XCTAssertNotNil(delivery.failureMessage)

        let recognitionStore = AppSettingsFake()
        let recognition = RecognitionLanguageSettingsViewModel(settings: recognitionStore)
        await recognition.load()
        await recognitionStore.setSaveFailureEnabled(true)
        await recognition.setFixedLanguage(code: "en")
        XCTAssertEqual(recognition.configuration, .automatic)
        XCTAssertNotNil(recognition.failureMessage)

        let shortcutStore = AppSettingsFake()
        let hotkey = AppHotkeyFake()
        let shortcut = ShortcutSettingsViewModel(settings: shortcutStore, hotkey: hotkey)
        await shortcut.load()
        await shortcutStore.setSaveFailureEnabled(true)
        await shortcut.setMode(.holdToTalk)
        XCTAssertEqual(shortcut.mode, .toggle)
        XCTAssertFalse(hotkey.calls.contains("hotkey.reconfigure.holdToTalk"))
        XCTAssertNotNil(shortcut.failureMessage)

        let launchStore = AppSettingsFake()
        let launchService = AppLaunchAtLoginFake()
        let launch = GeneralSettingsViewModel(
            settings: launchStore,
            controller: RecordingIntentControllerSpy(),
            launchAtLogin: launchService
        )
        await launch.load()
        await launchStore.setSaveFailureEnabled(true)
        await launch.setLaunchAtLoginEnabled(true)
        let persistedLaunch = try await launchStore.current().launchAtLogin
        XCTAssertFalse(launch.launchAtLoginEnabled)
        XCTAssertFalse(persistedLaunch)
        XCTAssertEqual(
            Array(launchService.calls.suffix(2)),
            ["launchAtLogin.set.true", "launchAtLogin.set.false"]
        )
        XCTAssertNotNil(launch.failureMessage)
    }

    func testLaunchAtLoginRequiresActualEnabledStateAndNeverPretendsApprovalSucceeded() async throws {
        let store = AppSettingsFake()
        let controller = RecordingIntentControllerSpy()
        let launch = AppLaunchAtLoginFake()
        launch.nextStateAfterEnable = .requiresApproval
        let model = GeneralSettingsViewModel(
            settings: store,
            controller: controller,
            launchAtLogin: launch
        )

        await model.load()
        await model.setLaunchAtLoginEnabled(true)

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginStatus, "Approval Required")

        launch.nextStateAfterEnable = .failed
        await model.setLaunchAtLoginEnabled(true)
        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginStatus, "Failed")

        launch.nextStateAfterEnable = .enabled
        await model.setLaunchAtLoginEnabled(true)
        let savedLaunchAtLogin = try await store.current().launchAtLogin
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertTrue(savedLaunchAtLogin)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Launch at Login is now on."
        )
    }

    func testHistoryDefaultsTrueAndPrivacyIntentsAreImmediateWithoutCompetingSave() async {
        let store = AppSettingsFake()
        let controller = RecordingIntentControllerSpy()
        let model = GeneralSettingsViewModel(
            settings: store,
            controller: controller,
            launchAtLogin: AppLaunchAtLoginFake()
        )

        await model.load()
        XCTAssertTrue(model.historyEnabled)

        model.setHistoryEnabled(false)
        model.setHistoryEnabled(true)
        model.clearHistory()
        let calls = await store.recordedCalls()

        XCTAssertEqual(
            controller.intents,
            [.setHistoryEnabled(false), .setHistoryEnabled(true), .clearHistory]
        )
        XCTAssertEqual(calls, ["settings.current"])
    }

    func testHistoryControlPendingAndFailurePhasesAreExplicit() async {
        let controller = RecordingIntentControllerSpy()
        let model = GeneralSettingsViewModel(
            settings: AppSettingsFake(),
            controller: controller,
            launchAtLogin: AppLaunchAtLoginFake()
        )

        controller.historyControlStatus = .applying(enabled: false)
        XCTAssertFalse(model.historyEnabled)
        XCTAssertTrue(model.historyControlIsPending)
        XCTAssertNil(model.historyControlWarning)

        controller.historyControlStatus = .failed(enabled: true, failure: .applyFailed)
        XCTAssertEqual(
            model.historyControlWarning,
            "History could not be changed. The previous privacy setting is still active."
        )

        controller.historyControlStatus = .failed(
            enabled: false,
            failure: .preferenceSaveFailed
        )
        XCTAssertEqual(
            model.historyControlWarning,
            "History changed for this run, but the preference could not be saved. It may differ after UtterInk restarts."
        )

        controller.historyControlStatus = .failed(enabled: false, failure: .clearFailed)
        XCTAssertEqual(
            model.historyControlWarning,
            "History disappeared from this window, but its saved records could not be cleared."
        )
        XCTAssertEqual(model.failureSymbol, "exclamationmark.triangle.fill")
    }

    func testDeliveryDefaultsAndExplanationsAreExactAndHonest() async throws {
        let store = AppSettingsFake()
        let model = GeneralSettingsViewModel(
            settings: store,
            controller: RecordingIntentControllerSpy(),
            launchAtLogin: AppLaunchAtLoginFake()
        )
        await model.load()

        XCTAssertEqual(model.deliveryPreference, .automaticPaste)
        XCTAssertEqual(
            model.deliveryExplanation,
            "Automatic Paste validates the original target before sending Command-V, then restores the prior clipboard only when guarded restoration remains safe. If delivery cannot proceed safely, the result remains available for explicit Copy."
        )

        await model.setDeliveryPreference(.copyOnly)
        let savedDelivery = try await store.current().deliveryPreference
        XCTAssertEqual(model.deliveryPreference, .copyOnly)
        XCTAssertEqual(savedDelivery, .copyOnly)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Delivery preference saved: Copy Only."
        )
        XCTAssertEqual(
            model.deliveryExplanation,
            "Copy Only uses your snapshotted pre-authorization to replace the clipboard with each completed dictation. It does not send Command-V and does not automatically restore the previous clipboard."
        )
        XCTAssertEqual(
            GeneralSettingsViewModel.safetyFallbackExplanation,
            "When automatic delivery is unsafe, UtterInk keeps the result available and waits for you to choose Copy; it does not claim the text was copied."
        )
    }

    func testRecognitionAutomaticAndFixedRoundTripThroughDedicatedModel() async throws {
        let store = AppSettingsFake()
        let model = RecognitionLanguageSettingsViewModel(settings: store)
        await model.load()

        XCTAssertEqual(model.configuration, .automatic)
        XCTAssertEqual(model.effectiveChoice, "Automatic")

        await model.setFixedLanguage(code: "en")
        let savedFixedRecognition = try await store.current().recognition
        XCTAssertEqual(model.configuration, .fixed(languageCode: "en"))
        XCTAssertEqual(model.effectiveChoice, "English (en)")
        XCTAssertEqual(savedFixedRecognition, .fixed(languageCode: "en"))
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Recognition language saved: English (en)."
        )

        await model.setAutomatic()
        let savedAutomaticRecognition = try await store.current().recognition
        XCTAssertEqual(model.configuration, .automatic)
        XCTAssertEqual(savedAutomaticRecognition, .automatic)
    }

    func testPermissionRowsRemainDistinctAndOpenExactPanes() async {
        let permissions = SettingsPermissionFake(
            microphone: .denied,
            accessibility: .granted
        )
        let systemSettings = AppSystemSettingsFake()
        let model = PermissionSettingsViewModel(
            permissions: permissions,
            systemSettings: systemSettings
        )

        await model.refresh()

        XCTAssertEqual(model.microphone.title, "Microphone")
        XCTAssertEqual(model.microphone.statusText, "Denied")
        XCTAssertEqual(model.microphone.symbol, "mic.slash.fill")
        XCTAssertEqual(model.accessibility.title, "Accessibility")
        XCTAssertEqual(model.accessibility.statusText, "Allowed")
        XCTAssertEqual(model.accessibility.symbol, "checkmark.shield.fill")

        model.openMicrophoneSettings()
        model.openAccessibilitySettings()
        XCTAssertEqual(
            systemSettings.calls,
            ["systemSettings.open.microphone", "systemSettings.open.accessibility"]
        )
    }

    func testShortcutModeEmptyConflictResetAndLiveReconfiguration() async throws {
        let store = AppSettingsFake()
        let hotkey = AppHotkeyFake()
        hotkey.hasConfiguredShortcut = false
        hotkey.hasConflict = true
        let model = ShortcutSettingsViewModel(settings: store, hotkey: hotkey)

        await model.load()
        XCTAssertEqual(model.mode, .toggle)
        XCTAssertEqual(model.shortcutStatus, "No shortcut recorded")
        XCTAssertEqual(model.conflictMessage, "This shortcut conflicts with another system or app shortcut.")

        await model.setMode(.holdToTalk)
        let savedShortcutMode = try await store.current().shortcutMode
        XCTAssertEqual(model.mode, .holdToTalk)
        XCTAssertEqual(savedShortcutMode, .holdToTalk)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Shortcut mode saved: Hold to Talk."
        )
        XCTAssertEqual(hotkey.calls.last, "hotkey.reconfigure.holdToTalk")

        model.resetShortcut()
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Shortcut reset. No shortcut recorded."
        )
        XCTAssertEqual(
            Array(hotkey.calls.suffix(2)),
            ["hotkey.reset", "hotkey.reconfigure.holdToTalk"]
        )
        XCTAssertEqual(model.shortcutStatus, "No shortcut recorded")

        hotkey.hasConfiguredShortcut = true
        model.recorderDidChange(hasShortcut: true)
        XCTAssertEqual(hotkey.calls.last, "hotkey.reconfigure.holdToTalk")
        XCTAssertEqual(model.shortcutStatus, "Shortcut recorded")
    }

    func testShortcutResetUsesLoadedModeEvenBeforeHotkeyArm() async {
        var settings = UserSettings.p0Default
        settings.shortcutMode = .holdToTalk
        let store = AppSettingsFake(value: settings)
        let hotkey = AppHotkeyFake()
        hotkey.currentMode = .toggle
        let model = ShortcutSettingsViewModel(settings: store, hotkey: hotkey)

        await model.load()
        model.resetShortcut()

        XCTAssertEqual(model.mode, .holdToTalk)
        XCTAssertEqual(hotkey.currentMode, .holdToTalk)
        XCTAssertEqual(hotkey.calls.last, "hotkey.reconfigure.holdToTalk")
    }

    func testFailedDisableRollbackReflectsActualLaunchServiceState() async {
        var settings = UserSettings.p0Default
        settings.launchAtLogin = true
        let store = AppSettingsFake(value: settings)
        let launchService = AppLaunchAtLoginFake()
        launchService.state = .enabled
        let model = GeneralSettingsViewModel(
            settings: store,
            controller: RecordingIntentControllerSpy(),
            launchAtLogin: launchService
        )
        await model.load()
        await store.setSaveFailureEnabled(true)
        launchService.nextStateAfterEnable = .requiresApproval

        await model.setLaunchAtLoginEnabled(false)

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginStatus, "Approval Required")
        XCTAssertNotNil(model.failureMessage)
    }

    func testFutureSessionSettingsNeverMutateActiveSessionPresentation() async {
        let controller = RecordingIntentControllerSpy()
        let sessionID = SessionID()
        controller.state = PipelineState(
            stage: .recording,
            sessionID: sessionID,
            token: EffectToken(sessionID: sessionID, generation: 1),
            result: nil,
            failure: nil
        )
        controller.sessionPresentation = SessionPresentationContext(
            deliveryPreference: .automaticPaste
        )
        let originalState = controller.state
        let originalPresentation = controller.sessionPresentation
        let store = AppSettingsFake()
        let general = GeneralSettingsViewModel(
            settings: store,
            controller: controller,
            launchAtLogin: AppLaunchAtLoginFake()
        )
        let recognition = RecognitionLanguageSettingsViewModel(settings: store)
        await general.load()
        await recognition.load()

        await general.setDeliveryPreference(.copyOnly)
        await recognition.setFixedLanguage(code: "en")

        XCTAssertEqual(controller.state, originalState)
        XCTAssertEqual(controller.sessionPresentation, originalPresentation)
        XCTAssertTrue(controller.intents.isEmpty)
    }
}

private actor SettingsPermissionFake: PermissionService {
    let microphone: PermissionState
    let accessibility: PermissionState

    init(microphone: PermissionState, accessibility: PermissionState) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    func microphoneState() async -> PermissionState { microphone }
    func accessibilityState() async -> PermissionState { accessibility }
}
