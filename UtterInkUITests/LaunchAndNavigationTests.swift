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

        assertAccessibleText(requireElement("menu.status", in: app), contains: "Ready")
        assertEnabled("menu.start", in: app)
        assertAbsent("menu.stop", in: app)
        assertAbsent("menu.cancel", in: app)

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
