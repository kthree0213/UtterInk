import Foundation

package enum HistoryStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case corrupt
    case dirty
    case disabled
    case duplicateSession
    case generationOverflow
    case invalidRecord
    case locked
    case missingRecord
    case poisoned
    case staleGeneration
    case staleOperation
    case tombstoned
    case unsafeStorage
    case unsupportedSchema
    case writeFailed

    package var description: String {
        switch self {
        case .corrupt: return "history-store-corrupt"
        case .dirty: return "history-store-dirty"
        case .disabled: return "history-store-disabled"
        case .duplicateSession: return "history-store-duplicate-session"
        case .generationOverflow: return "history-store-generation-overflow"
        case .invalidRecord: return "history-store-invalid-record"
        case .locked: return "history-store-locked"
        case .missingRecord: return "history-store-missing-record"
        case .poisoned: return "history-store-poisoned"
        case .staleGeneration: return "history-store-stale-generation"
        case .staleOperation: return "history-store-stale-operation"
        case .tombstoned: return "history-store-tombstoned"
        case .unsafeStorage: return "history-store-unsafe-storage"
        case .unsupportedSchema: return "history-store-unsupported-schema"
        case .writeFailed: return "history-store-write-failed"
        }
    }
}

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
