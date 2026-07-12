import Foundation
import XCTest
import UtterInkCore
import UtterInkServices

final class LegacyCredentialMigratorTests: XCTestCase {
    func testPublicConstructionEntryPointsAreAvailable() throws {
        let reader = try LegacyDefaultsReader(suiteName: "dev.flowtype.FlowType")
        let service: any CredentialMigrationService = try LegacyCredentialMigrator(
            legacy: reader,
            credentials: MigratorFakeCredentials()
        )
        XCTAssertNotNil(service)
        XCTAssertEqual(LegacyDefaultsMap.bundled.entries.count, 4)
    }

    func testConcreteReaderUsesExplicitPersistentDomainAndRemovesOnlyRequestedKeys() throws {
        let suite = "dev.utterink.tests.legacy.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        UserDefaults.standard.setPersistentDomain(
            ["remove-a": "secret-a", "remove-b": "secret-b", "keep": "setting"],
            forName: suite
        )
        let reader = try LegacyDefaultsReader(suiteName: suite)

        XCTAssertEqual(try reader.persistentDomain()?["keep"] as? String, "setting")
        try reader.removeAtomically(keys: ["remove-a", "remove-b"])

        let verified = UserDefaults.standard.persistentDomain(forName: suite)
        XCTAssertNil(verified?["remove-a"])
        XCTAssertNil(verified?["remove-b"])
        XCTAssertEqual(verified?["keep"] as? String, "setting")
    }

    func testConcreteReaderTreatsMissingDomainAndKeysAsNonErrors() throws {
        let suite = "dev.utterink.tests.legacy.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let reader = try LegacyDefaultsReader(suiteName: suite)
        XCTAssertNil(try reader.persistentDomain())
        XCTAssertNoThrow(try reader.removeAtomically(keys: ["missing"]))
    }

    func testDirectProfileSecretMigratesOnlyAfterVerifiedReadbackAndIsIdempotent() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: "direct-secret"])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let firstResult = await migrator.migrate(profileID: profileID)
        XCTAssertEqual(firstResult, .migrated)
        XCTAssertNil(try legacy.value(forKey: key))
        let stored = await credentials.value(profileID: profileID)
        XCTAssertEqual(stored, "direct-secret")
        let repeated = await migrator.migrate(profileID: profileID)
        XCTAssertEqual(repeated, .noLegacyValue)
        XCTAssertEqual(legacy.removalBatches, [[key]])
    }

    func testGlobalKeysResolveOnlyToUniqueMatchingProvider() async throws {
        let openRouterID = UUID()
        let minimaxID = UUID()
        let profiles = try legacyProfiles([
            .init(id: openRouterID, template: "openrouter", title: "OpenRouter", customURL: nil),
            .init(id: minimaxID, template: "minimax", title: "MiniMax", customURL: nil)
        ])
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "openRouterApiKey": "router-secret",
            "minimaxApiKey": "minimax-secret"
        ])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let openRouterResult = await migrator.migrate(profileID: openRouterID)
        let minimaxResult = await migrator.migrate(profileID: minimaxID)
        let openRouterValue = await credentials.value(profileID: openRouterID)
        let minimaxValue = await credentials.value(profileID: minimaxID)
        XCTAssertEqual(openRouterResult, .migrated)
        XCTAssertEqual(minimaxResult, .migrated)
        XCTAssertEqual(openRouterValue, "router-secret")
        XCTAssertEqual(minimaxValue, "minimax-secret")
    }

    func testGlobalKeyWithZeroOrMultipleCandidatesFailsClosed() async throws {
        let first = UUID()
        let second = UUID()
        let unrelated = UUID()
        let profiles = try legacyProfiles([
            .init(id: first, template: "openrouter", title: "One", customURL: nil),
            .init(id: second, template: "openrouter", title: "Two", customURL: nil)
        ])
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "openRouterApiKey": "ambiguous-secret",
            "minimaxApiKey": "orphan-secret"
        ])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let ambiguous = await migrator.migrate(profileID: first)
        let orphan = await migrator.migrate(profileID: unrelated)
        XCTAssertEqual(ambiguous, .conflict)
        XCTAssertEqual(orphan, .conflict)
        XCTAssertEqual(try legacy.value(forKey: "openRouterApiKey") as? String, "ambiguous-secret")
        XCTAssertEqual(try legacy.value(forKey: "minimaxApiKey") as? String, "orphan-secret")
        XCTAssertTrue(legacy.removalBatches.isEmpty)
    }

    func testEqualDirectAndGlobalValuesAreOneLogicalSecretAndRemovedAtomically() async throws {
        let profileID = UUID()
        let directKey = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": try legacyProfiles([.init(id: profileID, template: "openrouter", title: "OR", customURL: nil)]),
            directKey: "same-secret",
            "openRouterApiKey": "same-secret"
        ])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.migrate(profileID: profileID)
        XCTAssertEqual(result, .migrated)
        XCTAssertEqual(Set(legacy.removalBatches.single ?? []), Set([directKey, "openRouterApiKey"]))
    }

    func testDifferentDirectAndGlobalValuesConflictAndRetainBoth() async throws {
        let profileID = UUID()
        let directKey = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": try legacyProfiles([.init(id: profileID, template: "openrouter", title: "OR", customURL: nil)]),
            directKey: "direct-canary",
            "openRouterApiKey": "global-canary"
        ])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.migrate(profileID: profileID)
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(try legacy.value(forKey: directKey) as? String, "direct-canary")
        XCTAssertEqual(try legacy.value(forKey: "openRouterApiKey") as? String, "global-canary")
        let stored = await credentials.value(profileID: profileID)
        XCTAssertNil(stored)
    }

    func testBlankWhitespaceSecretIsNeverWritten() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: " \n\t "])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.migrate(profileID: profileID)
        let stored = await credentials.value(profileID: profileID)
        XCTAssertEqual(result, .noLegacyValue)
        XCTAssertNil(stored)
        XCTAssertNotNil(try legacy.value(forKey: key))
    }

    func testSecureEqualRemovesPlaintextAndSecureDifferentConflicts() async throws {
        let equalID = UUID()
        let differentID = UUID()
        let equalKey = "llmP.\(equalID.uuidString).apiKey"
        let differentKey = "llmP.\(differentID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [equalKey: "equal", differentKey: "legacy"])
        let credentials = MigratorFakeCredentials(values: [equalID: "equal", differentID: "secure"])
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let equalResult = await migrator.migrate(profileID: equalID)
        XCTAssertEqual(equalResult, .alreadySecure)
        XCTAssertNil(try legacy.value(forKey: equalKey))
        let differentResult = await migrator.migrate(profileID: differentID)
        XCTAssertEqual(differentResult, .conflict)
        XCTAssertEqual(try legacy.value(forKey: differentKey) as? String, "legacy")
        let stored = await credentials.value(profileID: differentID)
        XCTAssertEqual(stored, "secure")
    }

    func testWriteReadReadbackAndRemovalFailuresReturnInaccessibleWithoutIntentionalDeletion() async throws {
        for failure in MigratorFakeCredentials.Failure.allCases {
            let profileID = UUID()
            let key = "llmP.\(profileID.uuidString).apiKey"
            let legacy = MigratorFakeLegacy(values: [key: "failure-canary"])
            let credentials = MigratorFakeCredentials(failure: failure)
            let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

            let result = await migrator.migrate(profileID: profileID)
            XCTAssertEqual(result, .inaccessible, "\(failure)")
            XCTAssertEqual(try legacy.value(forKey: key) as? String, "failure-canary")
        }

        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: "remove-canary"], removeFails: true)
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)
        let removeResult = await migrator.migrate(profileID: profileID)
        XCTAssertEqual(removeResult, .inaccessible)
        XCTAssertEqual(try legacy.value(forKey: key) as? String, "remove-canary")
    }

    func testLegacyReadInaccessibleReturnsInaccessible() async throws {
        let legacy = MigratorFakeLegacy(values: [:], readFails: true)
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: MigratorFakeCredentials(), map: .bundled)
        let result = await migrator.migrate(profileID: UUID())
        XCTAssertEqual(result, .inaccessible)
    }

    func testKeepSecureRequiresSecureReadThenAtomicallyRemovesAllRelevantPlaintext() async throws {
        let profileID = UUID()
        let directKey = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": try legacyProfiles([.init(id: profileID, template: "openrouter", title: "OR", customURL: nil)]),
            directKey: "legacy-a",
            "openRouterApiKey": "legacy-b"
        ])
        let credentials = MigratorFakeCredentials(values: [profileID: "secure"])
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.resolve(profileID: profileID, choice: .keepSecure)
        XCTAssertEqual(result, .alreadySecure)
        XCTAssertEqual(Set(legacy.removalBatches.single ?? []), Set([directKey, "openRouterApiKey"]))
        let stored = await credentials.value(profileID: profileID)
        XCTAssertEqual(stored, "secure")
    }

    func testKeepSecureWithoutSecureItemFailsClosed() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: "legacy"])
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: MigratorFakeCredentials(), map: .bundled)

        let result = await migrator.resolve(profileID: profileID, choice: .keepSecure)
        XCTAssertEqual(result, .inaccessible)
        XCTAssertNotNil(try legacy.value(forKey: key))
    }

    func testReplaceSecureWithLegacyVerifiesAndRemoves() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: "replacement"])
        let credentials = MigratorFakeCredentials(values: [profileID: "old"])
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.resolve(profileID: profileID, choice: .replaceSecureWithLegacy)
        XCTAssertEqual(result, .migrated)
        XCTAssertNil(try legacy.value(forKey: key))
        let stored = await credentials.value(profileID: profileID)
        XCTAssertEqual(stored, "replacement")
    }

    func testErrorsAndDescriptionsNeverContainSecretCanary() async throws {
        let canary = "SECRET-CANARY-DO-NOT-LEAK"
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [key: canary])
        let credentials = MigratorFakeCredentials(failure: .write)
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.migrate(profileID: profileID)
        XCTAssertFalse(String(describing: result).contains(canary))
        XCTAssertFalse(String(reflecting: result).contains(canary))
        XCTAssertFalse(String(describing: migrator).contains(canary))
    }
}

private struct MigratorLegacyProfile: Encodable {
    let id: UUID
    let template: String
    let title: String
    let customOpenAIBaseURL: String?

    init(id: UUID, template: String, title: String, customURL: String?) {
        self.id = id
        self.template = template
        self.title = title
        self.customOpenAIBaseURL = customURL
    }
}

private func legacyProfiles(_ profiles: [MigratorLegacyProfile]) throws -> Data {
    try JSONEncoder().encode(profiles)
}

private final class MigratorFakeLegacy: LegacyDefaultsAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private let readFails: Bool
    private let removeFails: Bool
    private(set) var removalBatches: [[String]] = []

    init(values: [String: Any], readFails: Bool = false, removeFails: Bool = false) {
        self.values = values
        self.readFails = readFails
        self.removeFails = removeFails
    }

    func persistentDomain() throws -> [String: Any]? {
        try lock.withLock {
            if readFails { throw MigratorFakeError.unavailable }
            return values
        }
    }

    func removeAtomically(keys: Set<String>) throws {
        try lock.withLock {
            if removeFails { throw MigratorFakeError.unavailable }
            removalBatches.append(keys.sorted())
            for key in keys { values.removeValue(forKey: key) }
        }
    }

    func value(forKey key: String) throws -> Any? {
        try persistentDomain()?[key]
    }
}

private actor MigratorFakeCredentials: CredentialStore {
    enum Failure: CaseIterable { case write, read, mismatch }
    private var values: [UUID: String]
    private let failure: Failure?

    init(values: [UUID: String] = [:], failure: Failure? = nil) {
        self.values = values
        self.failure = failure
    }

    func read(profileID: UUID) async throws -> SessionSecret? {
        if failure == .read { throw MigratorFakeError.unavailable }
        if failure == .mismatch, values[profileID] != nil {
            return SessionSecret(utf8: "forced-mismatch")
        }
        return values[profileID].map(SessionSecret.init(utf8:))
    }

    func write(_ secret: SessionSecret, profileID: UUID) async throws {
        if failure == .write { throw MigratorFakeError.unavailable }
        values[profileID] = try secret.withUTF8 { $0 }
    }

    func delete(profileID: UUID) async throws {
        values.removeValue(forKey: profileID)
    }

    func value(profileID: UUID) -> String? { values[profileID] }
}

private enum MigratorFakeError: Error { case unavailable }

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
