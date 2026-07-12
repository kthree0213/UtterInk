import Foundation
import UtterInkCore

package enum LegacyCredentialMigratorError: Error, Equatable, Sendable {
    case invalidMap
}

public actor LegacyCredentialMigrator: CredentialMigrationService {
    private let legacy: any LegacyDefaultsAccess
    private let credentials: any CredentialStore
    private let map: LegacyDefaultsMap
    private let directPattern: String
    private let globalMappings: [String: String]

    public init(
        legacy: LegacyDefaultsReader,
        credentials: any CredentialStore,
        map: LegacyDefaultsMap = .bundled
    ) throws {
        let configuration = try Self.validate(map: map)
        self.legacy = legacy
        self.credentials = credentials
        self.map = map
        self.directPattern = configuration.directPattern
        self.globalMappings = configuration.globalMappings
    }

    package init(
        legacy: any LegacyDefaultsAccess,
        credentials: any CredentialStore,
        map: LegacyDefaultsMap = .bundled
    ) throws {
        let configuration = try Self.validate(map: map)
        self.legacy = legacy
        self.credentials = credentials
        self.map = map
        self.directPattern = configuration.directPattern
        self.globalMappings = configuration.globalMappings
    }

    public func migrate(profileID: UUID) async -> CredentialMigrationResult {
        let resolution: LegacyResolution
        do {
            resolution = try resolveLegacy(profileID: profileID)
        } catch {
            return .inaccessible
        }

        switch resolution.state {
        case .none:
            return .noLegacyValue
        case .conflict:
            resolution.secret?.clear()
            return .conflict
        case .resolved:
            break
        }

        guard let legacySecret = resolution.secret else {
            return .noLegacyValue
        }
        defer { legacySecret.clear() }

        do {
            if let secure = try await credentials.read(profileID: profileID) {
                defer { secure.clear() }
                guard try secretsEqual(secure, legacySecret) else {
                    return .conflict
                }
                try legacy.removeAtomically(keys: resolution.keys)
                return .alreadySecure
            }

            try await credentials.write(legacySecret, profileID: profileID)
            guard let readback = try await credentials.read(profileID: profileID) else {
                return .inaccessible
            }
            defer { readback.clear() }
            guard try secretsEqual(readback, legacySecret) else {
                return .inaccessible
            }
            try legacy.removeAtomically(keys: resolution.keys)
            return .migrated
        } catch {
            return .inaccessible
        }
    }

    public func resolve(
        profileID: UUID,
        choice: CredentialConflictChoice
    ) async -> CredentialMigrationResult {
        let resolution: LegacyResolution
        do {
            resolution = try resolveLegacy(profileID: profileID, allowKnownValueConflict: choice == .keepSecure)
        } catch {
            return .inaccessible
        }

        switch choice {
        case .keepSecure:
            resolution.secret?.clear()
            guard resolution.state != .none, !resolution.keys.isEmpty else {
                return .noLegacyValue
            }
            guard resolution.state != .conflict else {
                return .conflict
            }
            do {
                guard let secure = try await credentials.read(profileID: profileID) else {
                    return .inaccessible
                }
                secure.clear()
                try legacy.removeAtomically(keys: resolution.keys)
                return .alreadySecure
            } catch {
                return .inaccessible
            }

        case .replaceSecureWithLegacy:
            guard resolution.state == .resolved, let legacySecret = resolution.secret else {
                resolution.secret?.clear()
                return resolution.state == .none ? .noLegacyValue : .conflict
            }
            defer { legacySecret.clear() }
            do {
                try await credentials.write(legacySecret, profileID: profileID)
                guard let readback = try await credentials.read(profileID: profileID) else {
                    return .inaccessible
                }
                defer { readback.clear() }
                guard try secretsEqual(readback, legacySecret) else {
                    return .inaccessible
                }
                try legacy.removeAtomically(keys: resolution.keys)
                return .migrated
            } catch {
                return .inaccessible
            }
        }
    }

    private func resolveLegacy(
        profileID: UUID,
        allowKnownValueConflict: Bool = false
    ) throws -> LegacyResolution {
        guard let domain = try legacy.persistentDomain() else {
            return LegacyResolution(state: .none, keys: [], secret: nil)
        }

        var candidates: [(key: String, secret: SessionSecret)] = []
        var structuralConflict = false

        let directKey = directPattern.replacingOccurrences(of: "<UUID>", with: profileID.uuidString)
        collectCandidate(key: directKey, from: domain, into: &candidates, structuralConflict: &structuralConflict)

        let profilesResult = decodeProfiles(from: domain["llmProviderProfilesV1"])
        for (key, provider) in globalMappings.sorted(by: { $0.key < $1.key }) {
            guard let raw = domain[key] else { continue }
            guard let string = raw as? String else {
                structuralConflict = true
                continue
            }
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard case .success(let profiles) = profilesResult else {
                structuralConflict = true
                continue
            }
            let matching = profiles.filter { $0.template == provider }
            guard matching.count == 1 else {
                structuralConflict = true
                continue
            }
            guard matching[0].id == profileID else { continue }
            candidates.append((key, SessionSecret(utf8: string)))
        }

        let keys = Set(candidates.map(\.key))
        guard !structuralConflict else {
            candidates.forEach { $0.secret.clear() }
            return LegacyResolution(state: .conflict, keys: keys, secret: nil)
        }
        guard let first = candidates.first else {
            return LegacyResolution(state: .none, keys: [], secret: nil)
        }

        var valuesEqual = true
        for candidate in candidates.dropFirst() {
            if try !secretsEqual(first.secret, candidate.secret) {
                valuesEqual = false
            }
            candidate.secret.clear()
        }
        guard valuesEqual || allowKnownValueConflict else {
            first.secret.clear()
            return LegacyResolution(state: .conflict, keys: keys, secret: nil)
        }
        if !valuesEqual {
            first.secret.clear()
            return LegacyResolution(state: .resolved, keys: keys, secret: nil)
        }
        return LegacyResolution(state: .resolved, keys: keys, secret: first.secret)
    }

    private func collectCandidate(
        key: String,
        from domain: [String: Any],
        into candidates: inout [(key: String, secret: SessionSecret)],
        structuralConflict: inout Bool
    ) {
        guard let raw = domain[key] else { return }
        guard let string = raw as? String else {
            structuralConflict = true
            return
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        candidates.append((key, SessionSecret(utf8: string)))
    }

    private func decodeProfiles(from value: Any?) -> Result<[LegacyProviderProfile], Error> {
        guard let value else { return .failure(LegacyProfileError.missing) }
        let data: Data
        if let stored = value as? Data {
            data = stored
        } else if let string = value as? String {
            data = Data(string.utf8)
        } else {
            return .failure(LegacyProfileError.invalid)
        }
        do {
            return .success(try JSONDecoder().decode([LegacyProviderProfile].self, from: data))
        } catch {
            return .failure(LegacyProfileError.invalid)
        }
    }

    private func secretsEqual(_ lhs: SessionSecret, _ rhs: SessionSecret) throws -> Bool {
        var left = try lhs.withUTF8 { Data($0.utf8) }
        var right = try rhs.withUTF8 { Data($0.utf8) }
        defer {
            left.resetBytes(in: 0..<left.count)
            right.resetBytes(in: 0..<right.count)
            left.removeAll()
            right.removeAll()
        }
        return left == right
    }

    private static func validate(map: LegacyDefaultsMap) throws -> MapConfiguration {
        let expectedKeys = Set([
            "llmProviderProfilesV1",
            "llmP.<UUID>.apiKey",
            "openRouterApiKey",
            "minimaxApiKey"
        ])
        let actualKeys = Set(map.entries.map(\.legacyKeyOrPattern))
        let domains = Set(map.entries.map(\.legacyDomain))
        guard actualKeys == expectedKeys,
              map.entries.count == expectedKeys.count,
              domains == ["dev.flowtype.FlowType"],
              !map.authorityHash.isEmpty,
              !map.supportEvidenceHashes.isEmpty,
              let direct = map.entries.first(where: { $0.profileMapping == "direct-uuid" }),
              direct.legacyKeyOrPattern == "llmP.<UUID>.apiKey"
        else {
            throw LegacyCredentialMigratorError.invalidMap
        }

        var globals: [String: String] = [:]
        for entry in map.entries {
            guard entry.profileMapping.hasPrefix("unique-provider:") else { continue }
            let provider = String(entry.profileMapping.dropFirst("unique-provider:".count))
            guard !provider.isEmpty, globals[entry.legacyKeyOrPattern] == nil else {
                throw LegacyCredentialMigratorError.invalidMap
            }
            globals[entry.legacyKeyOrPattern] = provider
        }
        guard globals == ["openRouterApiKey": "openrouter", "minimaxApiKey": "minimax"] else {
            throw LegacyCredentialMigratorError.invalidMap
        }
        return MapConfiguration(directPattern: direct.legacyKeyOrPattern, globalMappings: globals)
    }
}

private struct MapConfiguration {
    let directPattern: String
    let globalMappings: [String: String]
}

private struct LegacyProviderProfile: Decodable {
    let id: UUID
    let template: String
}

private enum LegacyProfileError: Error { case missing, invalid }

private struct LegacyResolution {
    enum State { case none, resolved, conflict }
    let state: State
    let keys: Set<String>
    let secret: SessionSecret?
}
