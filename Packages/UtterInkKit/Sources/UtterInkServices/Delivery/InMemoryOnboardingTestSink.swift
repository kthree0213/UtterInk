import Foundation
import UtterInkCore

public actor InMemoryOnboardingTestSink: OnboardingTestSink {
    private var continuations: [UUID: AsyncStream<(SessionID, String)>.Continuation] = [:]

    public init() {}

    public func deliver(_ text: String, sessionID: SessionID) {
        for continuation in continuations.values {
            continuation.yield((sessionID, text))
        }
    }

    public func values() -> AsyncStream<(SessionID, String)> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
