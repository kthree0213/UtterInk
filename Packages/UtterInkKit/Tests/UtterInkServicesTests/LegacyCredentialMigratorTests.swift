import Foundation
import CryptoKit
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

    func testConcreteReaderUsesTargetedCFPreferencesRemovalAndPreservesUnrelatedValues() throws {
        let preferences = MigratorFakePreferences(values: [
            "remove-a": "secret-a",
            "remove-b": "secret-b",
            "keep": "setting"
        ])
        let process = MigratorFakeProcessState(states: [false, false])
        let reader = try LegacyDefaultsReader(
            suiteName: "dev.example.Legacy",
            preferences: preferences,
            processState: process
        )

        try reader.removeAtomically(expectedFingerprints: [
            "remove-a": fingerprint("secret-a"),
            "remove-b": fingerprint("secret-b")
        ])

        XCTAssertEqual(preferences.copyRequests, [Set(["remove-a", "remove-b"]), Set(["remove-a", "remove-b"])])
        XCTAssertEqual(preferences.removeRequests, [Set(["remove-a", "remove-b"])])
        XCTAssertNil(preferences.value(forKey: "remove-a"))
        XCTAssertNil(preferences.value(forKey: "remove-b"))
        XCTAssertEqual(preferences.value(forKey: "keep") as? String, "setting")
        XCTAssertEqual(process.checkCount, 2)
    }

    func testConcreteReaderRejectsExpectedFingerprintMismatchBeforeMutation() throws {
        let preferences = MigratorFakePreferences(values: ["target": "changed-secret", "keep": "value"])
        let reader = try LegacyDefaultsReader(
            suiteName: "dev.example.Legacy",
            preferences: preferences,
            processState: MigratorFakeProcessState(states: [false])
        )

        XCTAssertThrowsError(
            try reader.removeAtomically(expectedFingerprints: ["target": fingerprint("expected-secret")])
        )
        XCTAssertTrue(preferences.removeRequests.isEmpty)
        XCTAssertEqual(preferences.value(forKey: "target") as? String, "changed-secret")
        XCTAssertEqual(preferences.value(forKey: "keep") as? String, "value")
    }

    func testConcreteReaderRejectsMissingOrWrongTypeTargetBeforeMutation() throws {
        for values in [[String: Any](), ["target": true]] {
            let preferences = MigratorFakePreferences(values: values)
            let reader = try LegacyDefaultsReader(
                suiteName: "dev.example.Legacy",
                preferences: preferences,
                processState: MigratorFakeProcessState(states: [false])
            )

            XCTAssertThrowsError(
                try reader.removeAtomically(expectedFingerprints: ["target": fingerprint("secret")])
            )
            XCTAssertTrue(preferences.removeRequests.isEmpty)
        }
    }

    func testConcreteReaderRequiresSynchronizationAndVerifiedAbsence() throws {
        let synchronizationFailure = MigratorFakePreferences(
            values: ["target": "secret"],
            synchronizeResult: false
        )
        let syncReader = try LegacyDefaultsReader(
            suiteName: "dev.example.Legacy",
            preferences: synchronizationFailure,
            processState: MigratorFakeProcessState(states: [false, false])
        )
        XCTAssertThrowsError(
            try syncReader.removeAtomically(expectedFingerprints: ["target": fingerprint("secret")])
        )

        let verificationFailure = MigratorFakePreferences(
            values: ["target": "secret"],
            retainRemovedValues: true
        )
        let verificationReader = try LegacyDefaultsReader(
            suiteName: "dev.example.Legacy",
            preferences: verificationFailure,
            processState: MigratorFakeProcessState(states: [false, false])
        )
        XCTAssertThrowsError(
            try verificationReader.removeAtomically(expectedFingerprints: ["target": fingerprint("secret")])
        )
        XCTAssertEqual(verificationFailure.copyRequests.count, 2)
    }

    func testConcreteReaderFailsClosedWhenLegacyProcessIsRunningAtEitherCheck() throws {
        for states in [[true], [false, true]] {
            let preferences = MigratorFakePreferences(values: ["target": "secret"])
            let reader = try LegacyDefaultsReader(
                suiteName: "dev.example.Legacy",
                preferences: preferences,
                processState: MigratorFakeProcessState(states: states)
            )

            XCTAssertThrowsError(
                try reader.removeAtomically(expectedFingerprints: ["target": fingerprint("secret")])
            )
            XCTAssertTrue(preferences.removeRequests.isEmpty)
            XCTAssertEqual(preferences.value(forKey: "target") as? String, "secret")
        }
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

    func testAmbiguousRequestedProviderConflictsWhileUnrelatedOrphanRemainsUntouched() async throws {
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
        XCTAssertEqual(orphan, .noLegacyValue)
        XCTAssertEqual(try legacy.value(forKey: "openRouterApiKey") as? String, "ambiguous-secret")
        XCTAssertEqual(try legacy.value(forKey: "minimaxApiKey") as? String, "orphan-secret")
        XCTAssertTrue(legacy.removalBatches.isEmpty)
    }

    func testUnrelatedAmbiguousGlobalDoesNotBlockDirectProfileMigration() async throws {
        let firstOpenRouter = UUID()
        let secondOpenRouter = UUID()
        let directProfile = UUID()
        let directKey = "llmP.\(directProfile.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(values: [
            "llmProviderProfilesV1": try legacyProfiles([
                .init(id: firstOpenRouter, template: "openrouter", title: "One", customURL: nil),
                .init(id: secondOpenRouter, template: "openrouter", title: "Two", customURL: nil),
                .init(id: directProfile, template: "custom", title: "Direct", customURL: "https://example.com/v1")
            ]),
            "openRouterApiKey": "ambiguous-global",
            directKey: "direct-secret"
        ])
        let credentials = MigratorFakeCredentials()
        let migrator = try LegacyCredentialMigrator(legacy: legacy, credentials: credentials, map: .bundled)

        let result = await migrator.migrate(profileID: directProfile)

        XCTAssertEqual(result, .migrated)
        XCTAssertNil(try legacy.value(forKey: directKey))
        XCTAssertEqual(try legacy.value(forKey: "openRouterApiKey") as? String, "ambiguous-global")
        let stored = await credentials.value(profileID: directProfile)
        XCTAssertEqual(stored, "direct-secret")
    }

    func testChangedTargetAfterResolutionAbortsCleanupAndPreservesChangedPlaintext() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(
            values: [key: "resolved-secret"],
            beforeRemoval: { $0[key] = "new-secret-from-legacy-process" }
        )
        let migrator = try LegacyCredentialMigrator(
            legacy: legacy,
            credentials: MigratorFakeCredentials(),
            map: .bundled
        )

        let result = await migrator.migrate(profileID: profileID)

        XCTAssertEqual(result, .inaccessible)
        XCTAssertEqual(try legacy.value(forKey: key) as? String, "new-secret-from-legacy-process")
        XCTAssertTrue(legacy.removalBatches.isEmpty)
    }

    func testTwoKeyCleanupAbortsWholeBatchWhenEitherExpectedValueChanges() async throws {
        for changedKeyKind in 0..<2 {
            let profileID = UUID()
            let directKey = "llmP.\(profileID.uuidString).apiKey"
            let globalKey = "openRouterApiKey"
            let changedKey = changedKeyKind == 0 ? directKey : globalKey
            let legacy = MigratorFakeLegacy(
                values: [
                    "llmProviderProfilesV1": try legacyProfiles([
                        .init(id: profileID, template: "openrouter", title: "OR", customURL: nil)
                    ]),
                    directKey: "equal-secret",
                    globalKey: "equal-secret"
                ],
                beforeRemoval: { $0[changedKey] = "changed-secret" }
            )
            let migrator = try LegacyCredentialMigrator(
                legacy: legacy,
                credentials: MigratorFakeCredentials(),
                map: .bundled
            )

            let result = await migrator.migrate(profileID: profileID)

            XCTAssertEqual(result, .inaccessible)
            XCTAssertNotNil(try legacy.value(forKey: directKey))
            XCTAssertNotNil(try legacy.value(forKey: globalKey))
            XCTAssertTrue(legacy.removalBatches.isEmpty)
        }
    }

    func testUnrelatedConcurrentSettingChangeSurvivesTargetedCleanup() async throws {
        let profileID = UUID()
        let key = "llmP.\(profileID.uuidString).apiKey"
        let legacy = MigratorFakeLegacy(
            values: [key: "secret", "unrelated": "old"],
            beforeRemoval: { $0["unrelated"] = "new" }
        )
        let migrator = try LegacyCredentialMigrator(
            legacy: legacy,
            credentials: MigratorFakeCredentials(),
            map: .bundled
        )

        let result = await migrator.migrate(profileID: profileID)

        XCTAssertEqual(result, .migrated)
        XCTAssertNil(try legacy.value(forKey: key))
        XCTAssertEqual(try legacy.value(forKey: "unrelated") as? String, "new")
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
    private let beforeRemoval: ((inout [String: Any]) -> Void)?
    private(set) var removalBatches: [[String]] = []

    init(
        values: [String: Any],
        readFails: Bool = false,
        removeFails: Bool = false,
        beforeRemoval: ((inout [String: Any]) -> Void)? = nil
    ) {
        self.values = values
        self.readFails = readFails
        self.removeFails = removeFails
        self.beforeRemoval = beforeRemoval
    }

    func persistentDomain() throws -> [String: Any]? {
        try lock.withLock {
            if readFails { throw MigratorFakeError.unavailable }
            return values
        }
    }

    func removeAtomically(expectedFingerprints: [String: String]) throws {
        try lock.withLock {
            if removeFails { throw MigratorFakeError.unavailable }
            beforeRemoval?(&values)
            for (key, expected) in expectedFingerprints {
                guard let current = values[key] as? String,
                      fingerprint(current) == expected
                else { throw MigratorFakeError.unavailable }
            }
            removalBatches.append(expectedFingerprints.keys.sorted())
            for key in expectedFingerprints.keys { values.removeValue(forKey: key) }
        }
    }

    func value(forKey key: String) throws -> Any? {
        try persistentDomain()?[key]
    }
}

private final class MigratorFakePreferences: LegacyPreferencesClient, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private let synchronizeResult: Bool
    private let retainRemovedValues: Bool
    private(set) var copyRequests: [Set<String>] = []
    private(set) var removeRequests: [Set<String>] = []

    init(
        values: [String: Any],
        synchronizeResult: Bool = true,
        retainRemovedValues: Bool = false
    ) {
        self.values = values
        self.synchronizeResult = synchronizeResult
        self.retainRemovedValues = retainRemovedValues
    }

    func copyMultiple(keys: Set<String>, applicationID: String) -> [String: Any]? {
        lock.withLock {
            copyRequests.append(keys)
            return values.filter { keys.contains($0.key) }
        }
    }

    func removeMultiple(keys: Set<String>, applicationID: String) {
        lock.withLock {
            removeRequests.append(keys)
            if !retainRemovedValues {
                for key in keys { values.removeValue(forKey: key) }
            }
        }
    }

    func synchronize(applicationID: String) -> Bool { synchronizeResult }

    func value(forKey key: String) -> Any? { lock.withLock { values[key] } }
}

private final class MigratorFakeProcessState: LegacyProcessStateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Bool]
    private(set) var checkCount = 0

    init(states: [Bool]) { self.states = states }

    func isRunning(bundleIdentifier: String) -> Bool {
        lock.withLock {
            checkCount += 1
            return states.isEmpty ? false : states.removeFirst()
        }
    }
}

private func fingerprint(_ value: String) -> String {
    var data = Data(value.utf8)
    defer {
        data.resetBytes(in: 0..<data.count)
        data.removeAll()
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
