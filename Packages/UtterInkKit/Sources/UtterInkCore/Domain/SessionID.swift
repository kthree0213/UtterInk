import Foundation

public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct EffectToken: Hashable, Sendable {
    public let sessionID: SessionID
    public let generation: UInt64

    public init(sessionID: SessionID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}
