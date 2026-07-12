import ApplicationServices
import AVFoundation
import UtterInkCore

enum MicrophoneAuthorizationStatus: Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

protocol MicrophoneAuthorizationQuery: Sendable {
    func authorizationStatus() -> MicrophoneAuthorizationStatus
}

protocol AccessibilityTrustQuery: Sendable {
    func isTrusted() -> Bool
}

public struct SystemPermissionService: PermissionService {
    private let microphone: any MicrophoneAuthorizationQuery
    private let accessibility: any AccessibilityTrustQuery

    public init() {
        microphone = SystemMicrophoneAuthorizationQuery()
        accessibility = SystemAccessibilityTrustQuery()
    }

    init(
        microphone: any MicrophoneAuthorizationQuery,
        accessibility: any AccessibilityTrustQuery
    ) {
        self.microphone = microphone
        self.accessibility = accessibility
    }

    public func microphoneState() async -> PermissionState {
        switch microphone.authorizationStatus() {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        }
    }

    public func accessibilityState() async -> PermissionState {
        accessibility.isTrusted() ? .granted : .denied
    }
}

private struct SystemMicrophoneAuthorizationQuery: MicrophoneAuthorizationQuery {
    func authorizationStatus() -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
}

private struct SystemAccessibilityTrustQuery: AccessibilityTrustQuery {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
