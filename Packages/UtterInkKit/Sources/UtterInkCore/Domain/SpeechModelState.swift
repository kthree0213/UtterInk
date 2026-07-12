import Foundation

public enum SpeechModelState: Equatable, Sendable {
    case missing(modelID: String)
    case downloading(modelID: String, progress: Double)
    case loading(modelID: String)
    case ready(modelID: String)
    case failed(modelID: String, code: DiagnosticCode, retryable: Bool)
}

public struct SpeechModelLease: Hashable, Sendable {
    public let id: UUID
    public let modelID: String
    public let generation: UInt64

    public init(id: UUID = UUID(), modelID: String, generation: UInt64) {
        self.id = id
        self.modelID = modelID
        self.generation = generation
    }
}

public struct SpeechModelDescriptor: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let approximateBytes: UInt64
    public let preset: String?

    public init(id: String, displayName: String, approximateBytes: UInt64, preset: String?) {
        self.id = id
        self.displayName = displayName
        self.approximateBytes = approximateBytes
        self.preset = preset
    }
}
