import XCTest
@testable import UtterInkCore

final class SessionSnapshotTests: XCTestCase {
    func testP0DefaultsAreRawLocalAndHistoryEnabled() {
        let settings = UserSettings.p0Default

        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertTrue(settings.showFloatingRecorder)
        XCTAssertEqual(settings.recognition, .automatic)
        XCTAssertEqual(settings.speechModelID, "small")
        XCTAssertEqual(settings.outputModes, [.raw])
        XCTAssertEqual(settings.selectedOutputModeID, OutputMode.rawID)
        XCTAssertTrue(settings.providerProfiles.isEmpty)
        XCTAssertNil(settings.selectedProviderProfileID)
        XCTAssertEqual(settings.shortcutMode, .toggle)
        XCTAssertTrue(settings.historyEnabled)
        XCTAssertEqual(settings.deliveryPreference, .automaticPaste)
        XCTAssertFalse(settings.onboardingCompletedV2)
        XCTAssertEqual(settings.onboardingStep, 0)
    }

    func testSnapshotCopiesOutputModeAndCredential() throws {
        let secretValue = UUID().uuidString
        var mode = OutputMode(id: UUID(), title: "Polish", skipsPolishing: false, instructions: "first")
        let secret = SessionSecret(utf8: secretValue)
        let snapshot = SessionSnapshot(
            id: SessionID(), target: .copyOnly,
            recognition: .fixed(languageCode: "en"), speechModelID: "small",
            outputMode: mode,
            provider: ProviderSelection(profileID: UUID(), baseURL: URL(string: "https://api.example.test/v1")!, modelID: "model", policy: .remoteHTTPS),
            historyGeneration: 4, historyEnabled: true, deliveryPreference: .automaticPaste,
            credential: secret.copy()
        )
        mode.instructions = "changed"
        secret.clear()
        XCTAssertEqual(snapshot.outputMode.instructions, "first")
        XCTAssertTrue(try XCTUnwrap(snapshot.credential).withUTF8 { $0 == secretValue })
    }

    func testSecretDescriptionNeverContainsValue() {
        let secretValue = UUID().uuidString
        let secret = SessionSecret(utf8: secretValue)

        XCTAssertEqual(String(describing: secret), "<SessionSecret>")
        XCTAssertEqual(String(reflecting: secret), "<SessionSecret>")
        XCTAssertFalse(String(describing: secret).contains(secretValue))
        XCTAssertFalse(String(reflecting: secret).contains(secretValue))
    }

    func testSettingsCodableRoundTripPreservesProviderEndpointPolicies() throws {
        let remoteProfile = ProviderProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            title: "Remote",
            baseURL: URL(string: "https://api.example.test/v1")!,
            modelID: "remote-model",
            policy: .remoteHTTPS
        )
        let loopbackProfile = ProviderProfile(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Local",
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            modelID: "local-model",
            policy: .loopbackHTTP
        )
        let settings = UserSettings(
            launchAtLogin: true,
            showFloatingRecorder: false,
            recognition: .fixed(languageCode: "fr"),
            speechModelID: "base",
            outputModes: [.raw, OutputMode(id: UUID(), title: "Clean", skipsPolishing: false, instructions: "Tidy")],
            selectedOutputModeID: OutputMode.rawID,
            providerProfiles: [remoteProfile, loopbackProfile],
            selectedProviderProfileID: loopbackProfile.id,
            shortcutMode: .holdToTalk,
            historyEnabled: false,
            deliveryPreference: .copyOnly,
            onboardingCompletedV2: true,
            onboardingStep: 3
        )

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UserSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.providerProfiles.map(\.policy), [.remoteHTTPS, .loopbackHTTP])
    }

    func testRawOutputModeIdentityAndP0OrderAreStable() {
        XCTAssertEqual(OutputMode.raw.id, OutputMode.rawID)
        XCTAssertEqual(OutputMode.rawID.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(OutputMode.raw.title, "Raw")
        XCTAssertTrue(OutputMode.raw.skipsPolishing)
        XCTAssertEqual(OutputMode.raw.instructions, "")
        XCTAssertEqual(UserSettings.p0Default.outputModes.map(\.id), [OutputMode.rawID])
    }

    func testSecretCopyRemainsIndependentAndClearIsRepeatable() throws {
        let secretValue = UUID().uuidString
        let original = SessionSecret(utf8: secretValue)
        let copied = original.copy()

        original.clear()
        original.clear()

        XCTAssertTrue(try original.withUTF8 { $0.isEmpty })
        XCTAssertTrue(try copied.withUTF8 { $0 == secretValue })

        copied.clear()
        copied.clear()

        XCTAssertTrue(try copied.withUTF8 { $0.isEmpty })
        XCTAssertTrue(try original.withUTF8 { $0.isEmpty })
    }

    func testSnapshotRetainsAllSuppliedValueFields() {
        let id = SessionID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let startedAt = Date(timeIntervalSince1970: 1_721_000_000)
        let target = DeliveryTarget.external(
            DeliveryTargetID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        )
        let recognition = RecognitionConfiguration.fixed(languageCode: "ja")
        let outputMode = OutputMode(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            title: "Polish",
            skipsPolishing: false,
            instructions: "Clarify"
        )
        let provider = ProviderSelection(
            profileID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
            baseURL: URL(string: "https://api.example.test/v1")!,
            modelID: "polish-model",
            policy: .remoteHTTPS
        )
        let snapshot = SessionSnapshot(
            id: id,
            startedAt: startedAt,
            target: target,
            recognition: recognition,
            speechModelID: "small",
            outputMode: outputMode,
            provider: provider,
            historyGeneration: 7,
            historyEnabled: false,
            deliveryPreference: .copyOnly,
            credential: nil
        )

        XCTAssertEqual(snapshot.id, id)
        XCTAssertEqual(snapshot.startedAt, startedAt)
        XCTAssertEqual(snapshot.target, target)
        XCTAssertEqual(snapshot.recognition, recognition)
        XCTAssertEqual(snapshot.speechModelID, "small")
        XCTAssertEqual(snapshot.outputMode, outputMode)
        XCTAssertEqual(snapshot.provider, provider)
        XCTAssertEqual(snapshot.historyGeneration, 7)
        XCTAssertFalse(snapshot.historyEnabled)
        XCTAssertEqual(snapshot.deliveryPreference, .copyOnly)
        XCTAssertNil(snapshot.credential)
    }
}
