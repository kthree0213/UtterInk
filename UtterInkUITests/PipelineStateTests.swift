import XCTest

final class PipelineStateTests: XCTestCase {
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

    func testRecordingScenarioShowsStopAndCancelActions() {
        let app = launch(.recording)

        assertAccessibleText(requireElement("floating.status", in: app), contains: "Listening")
        assertEnabled("floating.stop", in: app)
        assertAbsent("floating.cancel", in: app)
        assertAbsent("floating.start", in: app)
        _ = requireElement("floating.elapsed", in: app)
        _ = requireElement("floating.inputLevel", in: app)
        assertNonEmptyLabels(["floating.stop"], in: app)
    }

    func testRequestingPermissionScenarioShowsCancelOnly() {
        assertProgressScenario(
            .requestingPermission,
            status: "Requesting Permission"
        )
    }

    func testStoppingScenarioShowsCancelOnly() {
        assertProgressScenario(.stopping, status: "Stopping")
    }

    func testTranscribingScenarioShowsProgressAndCancelOnly() {
        assertProgressScenario(.transcribing, status: "Transcribing")
    }

    func testPolishingScenarioShowsCancelOnly() {
        assertProgressScenario(.polishing, status: "Polishing")
    }

    func testDeliveringScenarioShowsCancelOnly() {
        assertProgressScenario(.delivering, status: "Pasting")
    }

    func testPolishFallbackKeepsRawResultAndRecoveryActions() {
        let app = launch(.polishFallback)

        assertAccessibleText(requireElement("floating.status", in: app), contains: "Done")
        assertAccessibleText(
            requireElement("floating.warning", in: app),
            contains: "Raw text remains available"
        )
        assertCompletedRecoveryControls(in: app)
    }

    func testTargetChangedKeepsResultAndRequiresExplicitRecovery() {
        let app = launch(.targetChanged)

        assertAccessibleText(requireElement("floating.status", in: app), contains: "Done")
        assertAccessibleText(
            requireElement("floating.warning", in: app),
            contains: "original target changed"
        )
        assertCompletedRecoveryControls(in: app)
    }

    func testFailedScenarioKeepsRecoverableResultAndSpecificWarning() {
        let app = launch(.failed)

        assertAccessibleText(
            requireElement("floating.status", in: app),
            contains: "Needs Attention"
        )
        assertAccessibleText(
            requireElement("floating.warning", in: app),
            contains: "Automatic paste did not complete"
        )
        assertCompletedRecoveryControls(in: app)
    }

    private func assertProgressScenario(
        _ scenario: UITestScenarioName,
        status: String
    ) {
        let app = launch(scenario)

        assertAccessibleText(requireElement("floating.status", in: app), contains: status)
        assertEnabled("floating.cancel", in: app)
        assertAbsent("floating.start", in: app)
        assertAbsent("floating.stop", in: app)
        assertNonEmptyLabels(["floating.cancel"], in: app)
    }

    private func assertCompletedRecoveryControls(in app: XCUIApplication) {
        let identifiers = [
            "floating.dismiss",
            "floating.copyLatest",
            "floating.pasteLatest"
        ]
        for identifier in identifiers {
            assertEnabled(identifier, in: app)
        }
        assertAbsent("floating.start", in: app)
        assertAbsent("floating.viewLatest", in: app)
        assertNonEmptyLabels(identifiers, in: app)

        requireElement("floating.copyLatest", in: app).click()
        assertEventuallyAccessibleText(
            requireMenuBarStatusItem(in: app),
            contains: "Copied by you"
        )

        requireElement("floating.pasteLatest", in: app).click()
        assertEventuallyAccessibleText(
            requireMenuBarStatusItem(in: app),
            contains: "Paste event sent"
        )
    }

    private func launch(_ scenario: UITestScenarioName) -> XCUIApplication {
        let app = launchUtterInk(scenario)
        application = app
        return app
    }
}
