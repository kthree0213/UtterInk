import XCTest
@testable import UtterInkCore

final class ProductIdentityTests: XCTestCase {
    func testReleaseIdentity() {
        XCTAssertEqual(ProductIdentity.name, "UtterInk")
        XCTAssertEqual(ProductIdentity.bundleIdentifier, "dev.utterink.UtterInk")
        XCTAssertEqual(ProductIdentity.minimumMacOS, "14.0")
        XCTAssertEqual(ProductIdentity.releaseArchitecture, "arm64")
    }
}
