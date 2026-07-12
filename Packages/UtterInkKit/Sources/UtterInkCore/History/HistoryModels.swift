import Foundation

public enum HistoryOutcome: String, Codable, Sendable {
    case rawSaved, finalized, delivered, cancelled, failed
}

public struct HistoryRecord: Identifiable, Equatable, Codable, Sendable {
    public var id: SessionID { sessionID }
    public let sessionID: SessionID
    public let startedAt: Date
    public let rawText: String
    public var finalText: String?
    public var source: ResultSource
    public var warning: DiagnosticCode?
    public var delivery: DeliveryOutcome?
    public var outcome: HistoryOutcome

    public init(
        sessionID: SessionID,
        startedAt: Date,
        rawText: String,
        finalText: String?,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        outcome: HistoryOutcome
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.rawText = rawText
        self.finalText = finalText
        self.source = source
        self.warning = warning
        self.delivery = delivery
        self.outcome = outcome
    }
}

package struct HistoryEnvelope: Codable, Sendable {
    package let schemaVersion: Int
    package var generation: UInt64
    package var enabled: Bool
    package var records: [HistoryRecord]
    package var tombstones: Set<SessionID>

    package init(
        schemaVersion: Int,
        generation: UInt64,
        enabled: Bool,
        records: [HistoryRecord],
        tombstones: Set<SessionID>
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.enabled = enabled
        self.records = records
        self.tombstones = tombstones
    }
}
