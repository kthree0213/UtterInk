import Foundation
import XCTest
import UtterInkCore
import UtterInkServices

final class UserDefaultsSettingsStoreTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suites.removeAll()
        super.tearDown()
    }

    func testPublicInitializerIsAvailable() throws {
        let store: any SettingsStore = try UserDefaultsSettingsStore(defaults: makeDefaults())
        XCTAssertNotNil(store)
    }

    func testDefaultIsPersistedAsOneVersionedBlob() async throws {
        let defaults = makeDefaults()
        let legacy = SettingsFakeLegacy(values: [:])
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: legacy, legacyMap: .bundled)

        let current = try await store.current()
        XCTAssertEqual(current, .p0Default)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("utterink.") }, ["utterink.user-settings.v1"])
        XCTAssertNotNil(defaults.data(forKey: "utterink.user-settings.v1"))
    }

    func testRoundTripReplacesAndVerifiesCompleteSettingsBlob() async throws {
        let defaults = makeDefaults()
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: SettingsFakeLegacy(values: [:]), legacyMap: .bundled)
        let profileID = UUID()
        let remoteProfileID = UUID()
        let modeID = UUID()
        let settings = UserSettings(
            launchAtLogin: true,
            showFloatingRecorder: false,
            recognition: .fixed(languageCode: "ja"),
            speechModelID: "large-v3",
            outputModes: [.raw, OutputMode(id: modeID, title: "Clean", skipsPolishing: false, instructions: "clean")],
            selectedOutputModeID: modeID,
            providerProfiles: [
                ProviderProfile(id: profileID, title: "Local", baseURL: URL(string: "http://127.0.0.1:11434/v1")!, modelID: "model", policy: .loopbackHTTP),
                ProviderProfile(id: remoteProfileID, title: "Remote", baseURL: URL(string: "https://api.example.com/v1")!, modelID: "remote-model", policy: .remoteHTTPS)
            ],
            selectedProviderProfileID: profileID,
            shortcutMode: .holdToTalk,
            historyEnabled: false,
            deliveryPreference: .copyOnly,
            onboardingCompletedV2: true,
            onboardingStep: 5
        )

        try await store.save(settings)
        let current = try await store.current()
        XCTAssertEqual(current, settings)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("utterink.") }, ["utterink.user-settings.v1"])
    }

    func testConcurrentAtomicUpdatesPreserveBothMutations() async throws {
        let store = try UserDefaultsSettingsStore(
            defaults: makeDefaults(),
            legacy: SettingsFakeLegacy(values: [:]),
            legacyMap: .bundled
        )
        _ = try await store.current()

        async let delivery = store.update {
            $0.deliveryPreference = .copyOnly
        }
        async let floating = store.update {
            $0.showFloatingRecorder = false
        }
        _ = try await (delivery, floating)

        let final = try await store.current()
        XCTAssertEqual(final.deliveryPreference, .copyOnly)
        XCTAssertFalse(final.showFloatingRecorder)
    }

    func testMigratesAllSupportedNonSecretLegacyValues() async throws {
        let defaults = makeDefaults()
        let profileID = UUID()
        let modeID = UUID()
        let profiles = try JSONEncoder().encode([
            SettingsLegacyProfile(id: profileID, title: "Router", template: "openrouter", customOpenAIBaseURL: nil)
        ])
        let modes = try JSONEncoder().encode([
            SettingsLegacyMode(id: modeID, title: "Polish", skipsLLM: false, systemPrompt: "Make concise")
        ])
        let legacy = SettingsFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "llmP.\(profileID.uuidString).modelId": "router-model",
            "llmActiveProviderProfileId": profileID.uuidString,
            "outputModeProfilesV1": modes,
            "activeOutputModeProfileId": modeID.uuidString,
            "whisperKitModelId": "medium",
            "speechTranscriptionAutoDetectLanguage": false,
            "speechTranscriptionLanguageCode": "en",
            "shortcutMode": "pushToTalk",
            "launchAtLogin": true,
            "showFloatingRecorder": false,
            "historyEnabled": false,
            "deliveryPreference": "copyOnly",
            "onboardingCompletedV2": true,
            "onboardingStep": 3,
            "onboardingDismissed": true
        ])
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: legacy, legacyMap: .bundled)

        let value = try await store.current()
        XCTAssertEqual(value.providerProfiles.single?.id, profileID)
        XCTAssertEqual(value.providerProfiles.single?.modelID, "router-model")
        XCTAssertEqual(value.providerProfiles.single?.policy, .remoteHTTPS)
        XCTAssertEqual(value.selectedProviderProfileID, profileID)
        XCTAssertEqual(value.outputModes.map(\.id), [OutputMode.rawID, modeID])
        XCTAssertEqual(value.selectedOutputModeID, modeID)
        XCTAssertEqual(value.speechModelID, "medium")
        XCTAssertEqual(value.recognition, .fixed(languageCode: "en"))
        XCTAssertEqual(value.shortcutMode, .holdToTalk)
        XCTAssertTrue(value.launchAtLogin)
        XCTAssertFalse(value.showFloatingRecorder)
        XCTAssertFalse(value.historyEnabled)
        XCTAssertEqual(value.deliveryPreference, .copyOnly)
        XCTAssertTrue(value.onboardingCompletedV2)
        XCTAssertEqual(value.onboardingStep, 3)
    }

    func testAutomaticLanguageAndLegacyPrimaryLanguageConversions() async throws {
        let automatic = try UserDefaultsSettingsStore(
            defaults: makeDefaults(),
            legacy: SettingsFakeLegacy(values: ["speechTranscriptionAutoDetectLanguage": true, "speechTranscriptionLanguageCode": "zh"]),
            legacyMap: .bundled
        )
        let automaticValue = try await automatic.current()
        XCTAssertEqual(automaticValue.recognition, .automatic)

        let primary = try UserDefaultsSettingsStore(
            defaults: makeDefaults(),
            legacy: SettingsFakeLegacy(values: ["speechPrimaryLanguage": "en"]),
            legacyMap: .bundled
        )
        let primaryValue = try await primary.current()
        XCTAssertEqual(primaryValue.recognition, .fixed(languageCode: "en"))
    }

    func testInvalidLegacyEntriesAreSkippedAndRawIsAlwaysFirstAndSelectable() async throws {
        let defaults = makeDefaults()
        let invalidProfileID = UUID()
        let invalidModeID = UUID()
        let profiles = try JSONEncoder().encode([
            SettingsLegacyProfile(id: invalidProfileID, title: "Bad", template: "custom", customOpenAIBaseURL: "file:///tmp/not-network")
        ])
        let modes = try JSONEncoder().encode([
            SettingsLegacyMode(id: OutputMode.rawID, title: "Tampered Raw", skipsLLM: false, systemPrompt: "secret behavior"),
            SettingsLegacyMode(id: invalidModeID, title: "", skipsLLM: false, systemPrompt: "")
        ])
        let legacy = SettingsFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "llmActiveProviderProfileId": invalidProfileID.uuidString,
            "outputModeProfilesV1": modes,
            "activeOutputModeProfileId": UUID().uuidString,
            "speechTranscriptionLanguageCode": "   ",
            "whisperKitModelId": "   "
        ])
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: legacy, legacyMap: .bundled)

        let value = try await store.current()
        XCTAssertEqual(value.outputModes.first, .raw)
        XCTAssertEqual(value.outputModes.filter { $0.id == OutputMode.rawID }, [.raw])
        XCTAssertEqual(value.selectedOutputModeID, OutputMode.rawID)
        XCTAssertTrue(value.providerProfiles.isEmpty)
        XCTAssertNil(value.selectedProviderProfileID)
        XCTAssertEqual(value.speechModelID, UserSettings.p0Default.speechModelID)
        XCTAssertEqual(value.recognition, UserSettings.p0Default.recognition)
    }

    func testDuplicateLegacyProfileUUIDsAreAllDroppedAndSelectionCleared() async throws {
        let defaults = makeDefaults()
        let duplicateID = UUID()
        let uniqueID = UUID()
        let profiles = try JSONEncoder().encode([
            SettingsLegacyProfile(id: duplicateID, title: "Custom", template: "custom", customOpenAIBaseURL: "https://custom.example/v1"),
            SettingsLegacyProfile(id: duplicateID, title: "Router", template: "openrouter", customOpenAIBaseURL: nil),
            SettingsLegacyProfile(id: uniqueID, title: "Unique", template: "openai", customOpenAIBaseURL: nil)
        ])
        let legacy = SettingsFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "llmActiveProviderProfileId": duplicateID.uuidString,
            "llmP.\(duplicateID.uuidString).modelId": "duplicate-model",
            "llmP.\(uniqueID.uuidString).modelId": "unique-model"
        ])
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: legacy, legacyMap: .bundled)

        let value = try await store.current()

        XCTAssertEqual(value.providerProfiles.map(\.id), [uniqueID])
        XCTAssertNil(value.selectedProviderProfileID)
        XCTAssertEqual(value.outputModes.first, .raw)
        XCTAssertEqual(value.selectedOutputModeID, OutputMode.rawID)
    }

    func testApiKeysAreNeverCopiedIntoNewDomainOrEncodedBlob() async throws {
        let defaults = makeDefaults()
        let profileID = UUID()
        let canary = "APIKEY-CANARY-NEVER-COPY"
        let profiles = try JSONEncoder().encode([
            SettingsLegacyProfile(id: profileID, title: "Router", template: "openrouter", customOpenAIBaseURL: nil)
        ])
        let legacy = SettingsFakeLegacy(values: [
            "llmProviderProfilesV1": profiles,
            "llmP.\(profileID.uuidString).apiKey": canary,
            "openRouterApiKey": canary,
            "some.apiKey": canary
        ])
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: legacy, legacyMap: .bundled)

        _ = try await store.current()
        let representation = String(describing: defaults.dictionaryRepresentation())
        let blob = defaults.data(forKey: "utterink.user-settings.v1") ?? Data()
        XCTAssertFalse(representation.contains(canary))
        XCTAssertFalse(String(data: blob, encoding: .utf8)?.contains(canary) ?? true)
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.lowercased().contains("apikey") })
    }

    func testLegacyOnboardingDismissedAloneDoesNotCompleteV2AndAbsentPreferencesUseP0Defaults() async throws {
        let store = try UserDefaultsSettingsStore(
            defaults: makeDefaults(),
            legacy: SettingsFakeLegacy(values: ["onboardingDismissed": true]),
            legacyMap: .bundled
        )
        let value = try await store.current()
        XCTAssertFalse(value.onboardingCompletedV2)
        XCTAssertFalse(value.launchAtLogin)
        XCTAssertTrue(value.showFloatingRecorder)
        XCTAssertTrue(value.historyEnabled)
        XCTAssertEqual(value.deliveryPreference, .automaticPaste)
    }

    func testCorruptExistingBlobThrowsSanitizedErrorWithoutOverwriting() async throws {
        let defaults = makeDefaults()
        let corrupt = Data("CORRUPT-CANARY".utf8)
        defaults.set(corrupt, forKey: "utterink.user-settings.v1")
        let store = try UserDefaultsSettingsStore(defaults: defaults, legacy: SettingsFakeLegacy(values: [:]), legacyMap: .bundled)

        do {
            _ = try await store.current()
            XCTFail("expected corrupt settings error")
        } catch {
            XCTAssertEqual(defaults.data(forKey: "utterink.user-settings.v1"), corrupt)
            XCTAssertFalse(String(describing: error).contains("CORRUPT-CANARY"))
            XCTAssertFalse(String(reflecting: error).contains("CORRUPT-CANARY"))
        }
    }

    func testExistingSettingsKeyWithWrongPlistTypeThrowsWithoutOverwriting() async throws {
        let wrongValues: [Any] = [
            "wrong-type-canary",
            ["nested": "wrong-type-canary"],
            true
        ]
        for wrongValue in wrongValues {
            let defaults = makeDefaults()
            defaults.set(wrongValue, forKey: "utterink.user-settings.v1")
            let original = defaults.object(forKey: "utterink.user-settings.v1") as AnyObject?
            let store = try UserDefaultsSettingsStore(
                defaults: defaults,
                legacy: SettingsFakeLegacy(values: [:]),
                legacyMap: .bundled
            )

            do {
                _ = try await store.current()
                XCTFail("expected corrupt settings error")
            } catch {
                let after = defaults.object(forKey: "utterink.user-settings.v1") as AnyObject?
                XCTAssertTrue(original?.isEqual(after) == true)
                XCTAssertFalse(String(describing: error).contains("wrong-type-canary"))
            }
        }
    }

    func testSaveRejectsProviderURLSecretsAndPolicyMismatchBeforeWriting() async throws {
        let canary = "URL-SECRET-CANARY"
        let credentialURL = ["https://", "user:", canary, "@example.com/v1"].joined()
        let invalid: [(String, EndpointPolicy)] = [
            (credentialURL, .remoteHTTPS),
            ("https://example.com/v1?token=\(canary)", .remoteHTTPS),
            ("https://example.com/v1#\(canary)", .remoteHTTPS),
            ("http://example.com/v1", .remoteHTTPS),
            ("http://192.168.1.2:11434/v1", .loopbackHTTP),
            ("http://127.0.0.1:11434/v1", .remoteHTTPS),
            ("https://localhost:11434/v1", .loopbackHTTP),
            ("http://2130706433:11434/v1", .loopbackHTTP)
        ]

        for (urlString, policy) in invalid {
            let defaults = makeDefaults()
            let store = try UserDefaultsSettingsStore(
                defaults: defaults,
                legacy: SettingsFakeLegacy(values: [:]),
                legacyMap: .bundled
            )
            var settings = UserSettings.p0Default
            settings.providerProfiles = [
                ProviderProfile(
                    id: UUID(),
                    title: "Invalid",
                    baseURL: try XCTUnwrap(URL(string: urlString)),
                    modelID: "model",
                    policy: policy
                )
            ]

            do {
                try await store.save(settings)
                XCTFail("expected provider URL rejection for \(urlString)")
            } catch {
                XCTAssertNil(defaults.object(forKey: "utterink.user-settings.v1"))
                XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains(canary))
                XCTAssertFalse(String(describing: error).contains(canary))
            }
        }
    }

    func testSaveAcceptsEveryCanonicalLoopbackForm() async throws {
        for urlString in [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:11434/v1"
        ] {
            let defaults = makeDefaults()
            let store = try UserDefaultsSettingsStore(
                defaults: defaults,
                legacy: SettingsFakeLegacy(values: [:]),
                legacyMap: .bundled
            )
            var settings = UserSettings.p0Default
            settings.providerProfiles = [
                ProviderProfile(
                    id: UUID(),
                    title: "Loopback",
                    baseURL: try XCTUnwrap(URL(string: urlString)),
                    modelID: "model",
                    policy: .loopbackHTTP
                )
            ]

            try await store.save(settings)
            let current = try await store.current()
            XCTAssertEqual(current, settings)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "dev.utterink.tests.\(UUID().uuidString)"
        suites.append(name)
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }
}

private struct SettingsLegacyProfile: Encodable {
    let id: UUID
    let title: String
    let template: String
    let customOpenAIBaseURL: String?
}

private struct SettingsLegacyMode: Encodable {
    let id: UUID
    let title: String
    let skipsLLM: Bool
    let systemPrompt: String
}

private final class SettingsFakeLegacy: LegacyDefaultsAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any]) { self.values = values }

    func persistentDomain() throws -> [String: Any]? {
        lock.withLock { values }
    }

    func removeAtomically(
        expectedFingerprints: [String: String]
    ) throws -> LegacyCleanupOutcome {
        lock.withLock {
            for key in expectedFingerprints.keys { values.removeValue(forKey: key) }
            return .removed
        }
    }

}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
