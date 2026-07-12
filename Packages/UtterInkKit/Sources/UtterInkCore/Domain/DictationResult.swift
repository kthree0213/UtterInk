import Foundation

public enum ResultSource: String, Codable, Sendable {
    case raw, polished, rawFallback
}

public enum ResultPersistence: String, Codable, Sendable {
    case volatile, persistent
}

public enum DeliveryOutcome: Equatable, Codable, Sendable {
    case pasteEventDispatched
    case deliveredToOnboardingTest
    case copiedByPreference
    case copiedByUser
    case manualCopyRequired(DiagnosticCode)
}

public struct DictationResult: Equatable, Codable, Sendable {
    public let sessionID: SessionID
    public let startedAt: Date
    public let rawText: String
    public let finalText: String
    public let source: ResultSource
    public let warning: DiagnosticCode?
    public let delivery: DeliveryOutcome?
    public let persistence: ResultPersistence

    public init(
        sessionID: SessionID,
        startedAt: Date = Date(),
        rawText: String,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        persistence: ResultPersistence = .volatile
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.rawText = rawText
        self.finalText = finalText
        self.source = source
        self.warning = warning
        self.delivery = delivery
        self.persistence = persistence
    }
}
