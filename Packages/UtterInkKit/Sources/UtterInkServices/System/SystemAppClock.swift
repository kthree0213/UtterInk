import Foundation
import UtterInkCore

public struct SystemAppClock: AppClock {
    public init() {}

    public var now: Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
