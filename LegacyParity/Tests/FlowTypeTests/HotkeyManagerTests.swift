import XCTest
@testable import FlowType

final class HotkeyManagerTests: XCTestCase {
    @MainActor
    func testInitialization() {
        let manager = HotkeyManager()
        XCTAssertNotNil(manager)
    }
}
