import XCTest

final class LaunchAndNavigationTests: XCTestCase {
    private var application: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        application?.terminate()
        application = nil
        super.tearDown()
    }

    func testIdleScenarioShowsReadyStartActionAndSettingsRoutes() {
        let app = launch(.idle)
        openMenuBarExtra(in: app)

        assertEnabled("menu.start", in: app)
        assertAccessibleText(
            requireElement("menu.shortcutHint", in: app),
            contains: "Right"
        )
        assertAbsent("menu.stop", in: app)
        assertAbsent("menu.cancel", in: app)
        assertAbsent("menu.onboarding", in: app)

        requireElement("menu.settings", in: app).click()
        _ = requireElement("settings.sidebar", in: app)

        let routes = [
            "general",
            "permissions",
            "recognitionLanguage",
            "speechModel",
            "shortcuts",
            "outputModes",
            "provider",
            "diagnostics"
        ]
        for route in routes {
            requireElement("settings.route.\(route)", in: app).click()
            let destination = requireElement("settings.\(route)", in: app)
            assertInteractiveControlsHaveLabels(in: destination, context: route)
        }
    }

    func testHistoryScenarioOpensHistoryAndExposesRecovery() {
        let app = launch(.history)
        let latestSession = "10000000-0000-0000-0000-000000000002"
        openMenuBarExtra(in: app)
        requireElement("menu.history", in: app).click()

        _ = requireElement("history.list", in: app)
        assertEnabled("history.clearAll", in: app)

        let copy = requireElement("recovery.copy.\(latestSession)", in: app)
        let pasteAgain = requireElement("recovery.pasteAgain.\(latestSession)", in: app)
        let retry = requireElement("recovery.retryPolishing.\(latestSession)", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "History must expose Copy recovery")
        XCTAssertTrue(pasteAgain.exists && pasteAgain.isEnabled, "History must expose Paste Again recovery")
        XCTAssertTrue(retry.exists && retry.isEnabled, "History must expose Retry Polishing recovery")

        copy.click()
        assertEventuallyAccessibleText(
            requireElement("recovery.delivery.\(latestSession)", in: app),
            contains: "Copied by You"
        )

        requireElement("recovery.pasteAgain.\(latestSession)", in: app).click()
        assertEventuallyAccessibleText(
            requireElement("recovery.delivery.\(latestSession)", in: app),
            contains: "Paste event sent"
        )

        requireElement("recovery.retryPolishing.\(latestSession)", in: app).click()
        assertEventuallyAccessibleText(
            requireElement("history.preview.\(latestSession)", in: app),
            contains: "Deterministic polished retry"
        )
        assertAccessibleText(
            requireElement("history.variant.\(latestSession)", in: app),
            contains: "Polished"
        )
    }

    func testShortcutRecorderAndSpeechModelDownloadConfirmationAreInteractive() {
        let app = launch(.idle)
        openMenuBarExtra(in: app)
        requireElement("menu.settings", in: app).click()
        _ = requireElement("settings.sidebar", in: app)

        requireElement("settings.route.shortcuts", in: app).click()
        assertAccessibleText(
            requireElement("settings.shortcuts.status", in: app),
            contains: "Right Option"
        )
        let recorder = requireElement("settings.shortcuts.recorder", in: app)
        recorder.click()
        assertEventuallyAccessibleText(recorder, contains: "Recording")
        app.typeKey(.escape, modifierFlags: [])
        assertEventuallyAccessibleText(recorder, contains: "Right Option")

        requireElement("settings.route.speechModel", in: app).click()
        _ = requireElement("settings.speechModel.downloaded.small", in: app)
        requireElement("settings.speechModel.select.base", in: app).click()

        let downloadAlert = app.alerts["Download Speech Model?"]
        XCTAssertTrue(downloadAlert.waitForExistence(timeout: 5))
        XCTAssertTrue(
            downloadAlert.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "150 MB")
            ).firstMatch.exists,
            "The confirmation must disclose the approximate download size"
        )
        assertEnabled("settings.speechModel.confirmDownload", in: app)
        requireElement("settings.speechModel.cancelDownload", in: app).click()
        assertAbsent("settings.speechModel.confirmDownload", in: app)
        assertAccessibleText(
            requireElement("settings.speechModel.select.small", in: app),
            contains: "Selected"
        )
        assertAccessibleText(
            requireElement("settings.speechModel.select.base", in: app),
            contains: "Not selected"
        )
    }

    func testGeneralSettingsCanReplayCompletedOnboardingFromPrivacy() {
        let app = launch(.idle)
        openMenuBarExtra(in: app)
        requireElement("menu.settings", in: app).click()
        _ = requireElement("settings.sidebar", in: app)

        requireElement("settings.general.replayOnboarding", in: app).click()

        _ = requireElement("onboarding.flow", in: app)
        assertAccessibleText(
            requireElement("onboarding.step", in: app),
            contains: "Privacy"
        )
    }

    func testActiveHistoryClearDialogSupportsEscapeAndCancelsTheSession() {
        let app = launch(.historyActive)
        assertAccessibleText(requireElement("floating.status", in: app), contains: "Listening")

        openMenuBarExtra(in: app)
        requireElement("menu.history", in: app).click()
        _ = requireElement("history.list", in: app)

        let clearHistory = requireElement("history.clearAll", in: app)
        clearHistory.click()
        assertEnabled("history.cancelClear", in: app)
        assertEnabled("history.confirmClear", in: app)
        app.typeKey(.escape, modifierFlags: [])
        assertAbsent("history.confirmClear", in: app)
        XCTAssertTrue(clearHistory.exists && clearHistory.isEnabled)

        clearHistory.click()
        requireElement("history.confirmClear", in: app).click()
        _ = requireElement("history.empty", in: app)
        assertEventuallyAccessibleText(
            requireMenuBarStatusItem(in: app),
            contains: "Ready"
        )
    }

    func testOnboardingScenarioNavigatesToRecoverableTestResult() {
        let app = launch(.onboarding)
        _ = requireElement("onboarding.flow", in: app)

        let preflightSteps = [
            (title: "Privacy", identifier: "privacy"),
            (title: "Readiness", identifier: "readiness"),
            (title: "Shortcut Test", identifier: "shortcutTest")
        ]
        for step in preflightSteps {
            assertAccessibleText(requireElement("onboarding.step", in: app), contains: step.title)
            assertInteractiveControlsHaveLabels(
                in: requireElement("onboarding.step.\(step.identifier)", in: app),
                context: "onboarding.\(step.identifier)"
            )
            assertEnabled("onboarding.next", in: app)
            requireElement("onboarding.next", in: app).click()
        }

        assertAccessibleText(requireElement("onboarding.step", in: app), contains: "Test Dictation")
        assertInteractiveControlsHaveLabels(
            in: requireElement("onboarding.step.testDictation", in: app),
            context: "onboarding.testDictation.initial"
        )
        assertEnabled("onboarding.dictationStart", in: app)
        requireElement("onboarding.dictationStart", in: app).click()
        assertEnabled("onboarding.dictationStop", in: app)
        requireElement("onboarding.dictationStop", in: app).click()

        let result = requireElement("onboarding.testResult", in: app, timeout: 10)
        assertInteractiveControlsHaveLabels(
            in: requireElement("onboarding.step.testDictation", in: app),
            context: "onboarding.testDictation.result"
        )
        XCTAssertFalse(
            result.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Onboarding result must expose recoverable text"
        )
        assertEnabled("onboarding.copyResult", in: app)
        requireElement("onboarding.copyResult", in: app).click()
        assertEventuallyAccessibleText(
            requireMenuBarStatusItem(in: app),
            contains: "Copied by you"
        )

        let pasteField = requireElement("onboarding.pasteField", in: app)
        pasteField.click()
        // Digits remain deterministic across the user's active keyboard input source.
        let inAppTypingProbe = "27182818"
        pasteField.typeText(inAppTypingProbe)
        assertEventuallyAccessibleText(pasteField, contains: inAppTypingProbe)
    }

    private func launch(_ scenario: UITestScenarioName) -> XCUIApplication {
        let app = launchUtterInk(scenario)
        application = app
        return app
    }
}
