import Foundation

public enum DiagnosticCode: String, Codable, CaseIterable, Sendable, Error {
    case permissionMicrophone = "permission.microphone"
    case permissionAccessibility = "permission.accessibility"
    case audioStart = "audio.start"
    case audioFinalize = "audio.finalize"
    case transcriptionEmpty = "transcription.empty"
    case transcriptionFailed = "transcription.failed"
    case historyWrite = "history.write"
    case historyCorrupt = "history.corrupt"
    case credentialMissing = "credential.missing"
    case credentialMigrationConflict = "credential.migration_conflict"
    case polishTransport = "polish.transport"
    case polishAuthentication = "polish.authentication"
    case polishInvalidResponse = "polish.invalid_response"
    case deliveryTargetUnavailable = "delivery.target_unavailable"
    case deliveryTargetChanged = "delivery.target_changed"
    case deliveryPasteboardChanged = "delivery.pasteboard_changed"
    case deliveryDispatch = "delivery.dispatch"
    case cancelled = "session.cancelled"
}
