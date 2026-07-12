import Foundation

package protocol LegacyDefaultsAccess: Sendable {
    func persistentDomain() throws -> [String: Any]?
    func removeAtomically(keys: Set<String>) throws
}

package enum LegacyDefaultsAccessError: Error, Equatable, Sendable {
    case invalidDomain
    case removalVerificationFailed
}

public struct LegacyDefaultsReader: Sendable, LegacyDefaultsAccess {
    private static let mutationLock = NSLock()

    private let suiteName: String

    public init(suiteName: String) throws {
        let normalized = suiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LegacyDefaultsAccessError.invalidDomain
        }
        self.suiteName = normalized
    }

    package func persistentDomain() throws -> [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: suiteName)
    }

    package func removeAtomically(keys: Set<String>) throws {
        guard !keys.isEmpty else { return }

        try Self.mutationLock.withLock {
            guard var domain = UserDefaults.standard.persistentDomain(forName: suiteName) else {
                return
            }
            for key in keys {
                domain.removeValue(forKey: key)
            }
            UserDefaults.standard.setPersistentDomain(domain, forName: suiteName)

            let verified = UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:]
            guard keys.allSatisfy({ verified[$0] == nil }) else {
                throw LegacyDefaultsAccessError.removalVerificationFailed
            }
        }
    }
}
