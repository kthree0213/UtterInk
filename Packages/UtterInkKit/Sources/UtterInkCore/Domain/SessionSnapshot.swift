import Foundation

public struct SessionSnapshot: Sendable {
    public let id: SessionID
    public let startedAt: Date
    public let target: DeliveryTarget
    public let recognition: RecognitionConfiguration
    public let speechModelID: String
    public let outputMode: OutputMode
    public let provider: ProviderSelection?
    public let historyGeneration: UInt64
    public let historyEnabled: Bool
    public let deliveryPreference: DeliveryPreference
    public let credential: SessionSecret?

    public init(
        id: SessionID,
        startedAt: Date = Date(),
        target: DeliveryTarget,
        recognition: RecognitionConfiguration,
        speechModelID: String,
        outputMode: OutputMode,
        provider: ProviderSelection?,
        historyGeneration: UInt64,
        historyEnabled: Bool,
        deliveryPreference: DeliveryPreference,
        credential: SessionSecret?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.target = target
        self.recognition = recognition
        self.speechModelID = speechModelID
        self.outputMode = outputMode
        self.provider = provider
        self.historyGeneration = historyGeneration
        self.historyEnabled = historyEnabled
        self.deliveryPreference = deliveryPreference
        self.credential = credential
    }
}
