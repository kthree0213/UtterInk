import Foundation

public protocol AppClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct RecordingTelemetry: Equatable, Sendable {
    public let startedAt: Date
    public let inputLevel: Float

    public init(startedAt: Date, inputLevel: Float) {
        self.startedAt = startedAt
        self.inputLevel = inputLevel
    }
}

public struct SessionPresentationContext: Equatable, Sendable {
    public let deliveryPreference: DeliveryPreference

    public init(deliveryPreference: DeliveryPreference) {
        self.deliveryPreference = deliveryPreference
    }
}
