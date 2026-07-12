import Foundation

public struct RecordingHandle: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum PermissionState: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

public enum DictationIntent: Sendable {
    case start(SessionSnapshot)
    case microphoneResolved(PermissionState)
    case recordingStarted(RecordingHandle)
    case recordingStartFailed(DiagnosticCode)
    case stopRequested
    case audioFinalized(URL)
    case audioFinalizationFailed(DiagnosticCode)
    case transcriptionSucceeded(String)
    case transcriptionFailed(DiagnosticCode)
    case rawPersisted
    case rawPersistenceFailed(DiagnosticCode)
    case polishSucceeded(String)
    case polishFailed(DiagnosticCode)
    case finalPersisted
    case finalPersistenceFailed(DiagnosticCode)
    case deliveryFinished(DeliveryOutcome)
    case deliveryPersisted
    case deliveryPersistenceFailed(DiagnosticCode)
    case cancel
    case acknowledge
}
