import XCTest
@testable import UtterInkCore
@testable import UtterInkServices

final class SystemPermissionServiceTests: XCTestCase {
    func testMicrophoneStatusMappingUsesOnlyTheInjectedQuery() async {
        let cases: [(MicrophoneAuthorizationStatus, PermissionState)] = [
            (.authorized, .granted),
            (.denied, .denied),
            (.restricted, .denied),
            (.notDetermined, .notDetermined)
        ]

        for (authorization, expected) in cases {
            let microphone = MicrophoneQueryFake(status: authorization)
            let accessibility = AccessibilityQueryFake(trusted: true)
            let service = SystemPermissionService(
                microphone: microphone,
                accessibility: accessibility
            )

            let state = await service.microphoneState()

            XCTAssertEqual(state, expected)
            XCTAssertEqual(microphone.queryCount, 1)
            XCTAssertEqual(accessibility.queryCount, 0)
        }
    }

    func testAccessibilityStatusMappingUsesOnlyTheInjectedQuery() async {
        for (trusted, expected) in [(true, PermissionState.granted), (false, .denied)] {
            let microphone = MicrophoneQueryFake(status: .notDetermined)
            let accessibility = AccessibilityQueryFake(trusted: trusted)
            let service = SystemPermissionService(
                microphone: microphone,
                accessibility: accessibility
            )

            let state = await service.accessibilityState()

            XCTAssertEqual(state, expected)
            XCTAssertEqual(microphone.queryCount, 0)
            XCTAssertEqual(accessibility.queryCount, 1)
        }
    }

    func testPublicInitializerIsAvailableWithoutTriggeringAQuery() {
        let service = SystemPermissionService()
        XCTAssertNotNil(service as any PermissionService)
    }

    func testSystemAppClockSleepIsCancellable() async {
        let clock = SystemAppClock()
        let sleep = Task {
            try await clock.sleep(for: .seconds(30))
        }
        sleep.cancel()

        do {
            try await sleep.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
    }
}

private final class MicrophoneQueryFake: MicrophoneAuthorizationQuery, @unchecked Sendable {
    private let lock = NSLock()
    private let status: MicrophoneAuthorizationStatus
    private var queries = 0

    init(status: MicrophoneAuthorizationStatus) {
        self.status = status
    }

    var queryCount: Int {
        lock.withLock { queries }
    }

    func authorizationStatus() -> MicrophoneAuthorizationStatus {
        lock.withLock { queries += 1 }
        return status
    }
}

private final class AccessibilityQueryFake: AccessibilityTrustQuery, @unchecked Sendable {
    private let lock = NSLock()
    private let trusted: Bool
    private var queries = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    var queryCount: Int {
        lock.withLock { queries }
    }

    func isTrusted() -> Bool {
        lock.withLock { queries += 1 }
        return trusted
    }
}
