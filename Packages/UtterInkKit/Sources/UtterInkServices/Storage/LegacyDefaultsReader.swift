import AppKit
import CryptoKit
import Foundation

package protocol LegacyDefaultsAccess: Sendable {
    func persistentDomain() throws -> [String: Any]?
    func removeAtomically(expectedFingerprints: [String: String]) throws -> LegacyCleanupOutcome
}

package enum LegacyCleanupOutcome: Equatable, Sendable {
    case removed
    case pending
}

package protocol LegacyPreferencesClient: Sendable {
    func copyMultiple(keys: Set<String>, applicationID: String) -> [String: Any]?
    func removeMultiple(keys: Set<String>, applicationID: String)
    func synchronize(applicationID: String) -> Bool
}

package protocol LegacyProcessStateChecking: Sendable {
    func isRunning(bundleIdentifier: String) -> Bool
}

package enum LegacyDefaultsAccessError: Error, Equatable, Sendable {
    case invalidDomain
    case legacyProcessRunning
    case expectedValueMismatch
    case synchronizationFailed
    case removalVerificationFailed
}

public struct LegacyDefaultsReader: Sendable, LegacyDefaultsAccess {
    private static let mutationLock = NSLock()

    private let suiteName: String
    private let preferences: any LegacyPreferencesClient
    private let processState: any LegacyProcessStateChecking

    public init(suiteName: String) throws {
        let normalized = suiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LegacyDefaultsAccessError.invalidDomain
        }
        self.suiteName = normalized
        self.preferences = SystemLegacyPreferencesClient()
        self.processState = SystemLegacyProcessState()
    }

    package init(
        suiteName: String,
        preferences: any LegacyPreferencesClient,
        processState: any LegacyProcessStateChecking
    ) throws {
        let normalized = suiteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LegacyDefaultsAccessError.invalidDomain
        }
        self.suiteName = normalized
        self.preferences = preferences
        self.processState = processState
    }

    package func persistentDomain() throws -> [String: Any]? {
        UserDefaults.standard.persistentDomain(forName: suiteName)
    }

    package func removeAtomically(
        expectedFingerprints: [String: String]
    ) throws -> LegacyCleanupOutcome {
        guard !expectedFingerprints.isEmpty else { return .removed }

        return try Self.mutationLock.withLock {
            guard !processState.isRunning(bundleIdentifier: suiteName) else {
                throw LegacyDefaultsAccessError.legacyProcessRunning
            }

            guard preferences.synchronize(applicationID: suiteName) else {
                throw LegacyDefaultsAccessError.synchronizationFailed
            }

            let keys = Set(expectedFingerprints.keys)
            guard let current = preferences.copyMultiple(keys: keys, applicationID: suiteName) else {
                throw LegacyDefaultsAccessError.expectedValueMismatch
            }
            guard current.count == expectedFingerprints.count else {
                throw LegacyDefaultsAccessError.expectedValueMismatch
            }
            for (key, expectedFingerprint) in expectedFingerprints {
                guard let value = current[key] as? String,
                      legacyUTF8Fingerprint(value) == expectedFingerprint
                else {
                    throw LegacyDefaultsAccessError.expectedValueMismatch
                }
            }

            guard !processState.isRunning(bundleIdentifier: suiteName) else {
                throw LegacyDefaultsAccessError.legacyProcessRunning
            }

            preferences.removeMultiple(keys: keys, applicationID: suiteName)
            let synchronized = preferences.synchronize(applicationID: suiteName)

            guard let verified = preferences.copyMultiple(keys: keys, applicationID: suiteName) else {
                return .pending
            }
            if keys.allSatisfy({ verified[$0] == nil }) {
                return synchronized ? .removed : .pending
            }

            let exactExpectedValueRemains = expectedFingerprints.allSatisfy { key, fingerprint in
                guard let value = verified[key] as? String else { return false }
                return legacyUTF8Fingerprint(value) == fingerprint
            }
            if exactExpectedValueRemains {
                throw LegacyDefaultsAccessError.removalVerificationFailed
            }
            return .pending
        }
    }
}

package func legacyUTF8Fingerprint(_ value: String) -> String {
    var data = Data(value.utf8)
    defer {
        data.resetBytes(in: 0..<data.count)
        data.removeAll()
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct SystemLegacyPreferencesClient: LegacyPreferencesClient {
    func copyMultiple(keys: Set<String>, applicationID: String) -> [String: Any]? {
        let keyArray = keys.sorted() as CFArray
        let copied = CFPreferencesCopyMultiple(
            keyArray,
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return copied as? [String: Any]
    }

    func removeMultiple(keys: Set<String>, applicationID: String) {
        let keyArray = keys.sorted() as CFArray
        CFPreferencesSetMultiple(
            nil,
            keyArray,
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    func synchronize(applicationID: String) -> Bool {
        CFPreferencesSynchronize(
            applicationID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}

private struct SystemLegacyProcessState: LegacyProcessStateChecking {
    func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
