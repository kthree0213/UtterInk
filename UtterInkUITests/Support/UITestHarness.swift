import XCTest

enum UITestScenarioName: String, CaseIterable {
    case idle
    case requestingPermission
    case recording
    case stopping
    case transcribing
    case polishing
    case delivering
    case polishFallback
    case targetChanged
    case failed
    case history
    case historyActive
    case onboarding
}

extension XCTestCase {
    func launchUtterInk(
        _ scenario: UITestScenarioName,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let application = XCUIApplication()
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("UtterInkUITests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: isolatedHome,
                withIntermediateDirectories: true
            )
        } catch {
            XCTFail(
                "Could not create isolated UI-test home: \(error)",
                file: file,
                line: line
            )
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: isolatedHome)
        }

        application.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome.path
        application.launchEnvironment["HOME"] = isolatedHome.path
        application.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-uiTesting", scenario.rawValue,
        ]
        application.launch()
        let isRunning = application.state == .runningForeground
            || application.state == .runningBackground
        XCTAssertTrue(
            isRunning,
            "UtterInk did not start for \(scenario.rawValue); state=\(application.state.rawValue)",
            file: file,
            line: line
        )
        return application
    }

    func element(
        _ identifier: String,
        in application: XCUIApplication
    ) -> XCUIElement {
        application.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    @discardableResult
    func requireElement(
        _ identifier: String,
        in application: XCUIApplication,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let candidate = element(identifier, in: application)
        XCTAssertTrue(
            candidate.waitForExistence(timeout: timeout),
            "Missing accessibility identifier \(identifier). UI tree:\n\(application.debugDescription)",
            file: file,
            line: line
        )
        return candidate
    }

    func openMenuBarExtra(
        in application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let statusItem = requireMenuBarStatusItem(
            in: application,
            file: file,
            line: line
        )
        statusItem.click()
        _ = requireElement(
            "menu.status",
            in: application,
            timeout: 5,
            file: file,
            line: line
        )
    }

    @discardableResult
    func requireMenuBarStatusItem(
        in application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let statusItem = utterInkStatusItem(in: application)
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 5),
            "UtterInk menu-bar status item did not appear. UI tree:\n\(application.debugDescription)",
            file: file,
            line: line
        )
        let accessibleName = [statusItem.label, statusItem.title]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(
            accessibleName.isEmpty,
            """
            UtterInk menu-bar status item needs a non-empty accessible name. \
            label='\(statusItem.label)' title='\(statusItem.title)' \
            value='\(statusItem.value as? String ?? "")'. UI tree:\n\(application.debugDescription)
            """,
            file: file,
            line: line
        )
        return statusItem
    }

    private func utterInkStatusItem(
        in application: XCUIApplication
    ) -> XCUIElement {
        let statusItems = application.descendants(matching: .statusItem)
        let identified = statusItems.matching(identifier: "menu.statusItem").firstMatch
        if identified.waitForExistence(timeout: 2) {
            return identified
        }
        let named = statusItems.matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ OR title BEGINSWITH[c] %@",
                "UtterInk",
                "UtterInk"
            )
        ).firstMatch
        return named
    }

    func assertAccessibleText(
        _ element: XCUIElement,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = [
            element.label,
            element.title,
            element.value as? String ?? ""
        ].joined(separator: " ")
        XCTAssertTrue(
            rendered.localizedCaseInsensitiveContains(expected),
            "Expected \(element.identifier) to expose '\(expected)', got '\(rendered)'",
            file: file,
            line: line
        )
    }

    func assertEventuallyAccessibleText(
        _ element: XCUIElement,
        contains expected: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement else { return false }
            let rendered = [
                element.label,
                element.title,
                element.value as? String ?? ""
            ].joined(separator: " ")
            return rendered.localizedCaseInsensitiveContains(expected)
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected \(element.identifier) to eventually expose '\(expected)'",
            file: file,
            line: line
        )
    }

    func assertEnabled(
        _ identifier: String,
        in application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidate = requireElement(identifier, in: application, file: file, line: line)
        XCTAssertTrue(candidate.isEnabled, "\(identifier) should be enabled", file: file, line: line)
    }

    func assertAbsent(
        _ identifier: String,
        in application: XCUIApplication,
        timeout: TimeInterval = 0.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element(identifier, in: application).waitForExistence(timeout: timeout),
            "\(identifier) should not be available in this state",
            file: file,
            line: line
        )
    }

    func assertNonEmptyLabels(
        _ identifiers: [String],
        in application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for identifier in identifiers {
            let candidate = requireElement(identifier, in: application, file: file, line: line)
            let accessibleName = [candidate.label, candidate.title]
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(
                accessibleName.isEmpty,
                "Icon-only control \(identifier) needs a non-empty accessible name",
                file: file,
                line: line
            )
        }
    }

    func assertInteractiveControlsHaveLabels(
        in root: XCUIElement,
        context: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scrollBarFrames = root.descendants(matching: .scrollBar)
            .allElementsBoundByIndex
            .map(\.frame)
        let interactiveTypes: [XCUIElement.ElementType] = [
            .button,
            .checkBox,
            .popUpButton,
            .radioButton,
            .switch,
            .comboBox,
            .textField,
            .secureTextField,
            .textView,
            .slider,
            .stepper
        ]
        for type in interactiveTypes {
            for control in root.descendants(matching: type).allElementsBoundByIndex
                where control.exists {
                let isScrollBarImplementationDetail = scrollBarFrames.contains {
                    $0.contains(control.frame)
                }
                let isAnonymousInactiveImplementationDetail = control.identifier.isEmpty
                    && !control.isEnabled
                    && !control.isHittable
                    && control.frame.isEmpty
                if isScrollBarImplementationDetail || isAnonymousInactiveImplementationDetail {
                    continue
                }
                let accessibleName = [control.label, control.title]
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertFalse(
                    accessibleName.isEmpty,
                    """
                    Interactive control needs a non-empty accessible name. \
                    context='\(context ?? root.identifier)' type=\(type.rawValue) \
                    identifier='\(control.identifier)' label='\(control.label)' \
                    title='\(control.title)' value='\(control.value as? String ?? "")' \
                    enabled=\(control.isEnabled) hittable=\(control.isHittable) \
                    frame=\(control.frame). Element:\n\(control.debugDescription)
                    """,
                    file: file,
                    line: line
                )
            }
        }
    }
}
