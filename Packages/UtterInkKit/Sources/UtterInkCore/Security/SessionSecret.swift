import Foundation

public final class SessionSecret: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let lock = NSLock()
    private var bytes: Data

    public init(utf8: String) {
        self.bytes = Data(utf8.utf8)
    }

    private init(bytes: Data) {
        self.bytes = bytes
    }

    public func copy() -> SessionSecret {
        lock.withLock { SessionSecret(bytes: bytes) }
    }

    public func withUTF8<T>(_ body: (String) throws -> T) throws -> T {
        try lock.withLock {
            guard let value = String(data: bytes, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try body(value)
        }
    }

    public func clear() {
        lock.withLock {
            bytes.resetBytes(in: 0..<bytes.count)
            bytes.removeAll()
        }
    }

    public var description: String { "<SessionSecret>" }
    public var debugDescription: String { "<SessionSecret>" }

    deinit {
        clear()
    }
}
