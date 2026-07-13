import XCTest
import UtterInkCore
import UtterInkServices
@testable import UtterInk

@MainActor
final class ProviderPresentationTests: XCTestCase {
    func testOutputModesKeepRawFirstImmutableAndRejectEmptyInstructions() async throws {
        let store = AppSettingsFake()
        let model = OutputModeSettingsViewModel(settings: store)

        await model.load()
        XCTAssertEqual(model.modes, [.raw])
        XCTAssertTrue(model.canUse(.raw))
        let emptyAddSaved = await model.add(title: "Notes", instructions: "   ")
        let rawEditSaved = await model.update(
            id: OutputMode.rawID,
            title: "Changed",
            instructions: "Changed"
        )
        XCTAssertFalse(emptyAddSaved)
        XCTAssertFalse(rawEditSaved)
        await model.delete(id: OutputMode.rawID)
        XCTAssertEqual(model.modes, [.raw])

        let polishAddSaved = await model.add(
            title: "Notes",
            instructions: "Make this concise."
        )
        XCTAssertTrue(polishAddSaved)
        XCTAssertEqual(model.accessibilityEvent?.message, "Output mode added.")
        let saved = try await store.current()
        XCTAssertEqual(saved.outputModes.first, .raw)
        XCTAssertEqual(saved.outputModes.count, 2)
        XCTAssertFalse(saved.outputModes[1].skipsPolishing)
        XCTAssertEqual(saved.outputModes[1].instructions, "Make this concise.")
    }

    func testDeletingSelectedPolishModeFallsBackToRawWithoutOverwritingOtherSettings() async throws {
        let polish = OutputMode(
            id: UUID(),
            title: "Notes",
            skipsPolishing: false,
            instructions: "Make this concise."
        )
        var settings = UserSettings.p0Default
        settings.outputModes = [.raw, polish]
        settings.selectedOutputModeID = polish.id
        settings.speechModelID = "large-v3"
        let store = AppSettingsFake(value: settings)
        let model = OutputModeSettingsViewModel(settings: store)

        await model.load()
        await model.delete(id: polish.id)

        let saved = try await store.current()
        XCTAssertEqual(saved.outputModes, [.raw])
        XCTAssertEqual(saved.selectedOutputModeID, OutputMode.rawID)
        XCTAssertEqual(saved.speechModelID, "large-v3")
    }

    func testRawWorksWithoutProfileOrCredential() async {
        let model = ProviderSettingsViewModel(
            settings: AppSettingsFake(),
            credentials: ProviderCredentialFake(),
            migration: ProviderMigrationFake(),
            validation: ProviderValidationFake()
        )

        await model.load()
        XCTAssertTrue(model.canUse(.raw))
        XCTAssertFalse(
            model.canUse(
                OutputMode(id: UUID(), title: "Polish", skipsPolishing: false, instructions: "Fix it")
            )
        )
        XCTAssertNil(model.egressDisclosure)
    }

    func testIncompleteSelectedProfileIsNeverInUseAndSelectedReadyProfileIs() async {
        let profile = providerProfile()
        var settings = UserSettings.p0Default
        settings.providerProfiles = [profile]
        settings.selectedProviderProfileID = profile.id
        let store = AppSettingsFake(value: settings)
        let credentials = ProviderCredentialFake()
        let validation = ProviderValidationFake(
            result: .ready(normalizedHost: "api.example.test", modelID: "model-a")
        )
        let model = ProviderSettingsViewModel(
            settings: store,
            credentials: credentials,
            migration: ProviderMigrationFake(),
            validation: validation
        )

        await model.load()
        XCTAssertEqual(model.statusText(for: profile.id), "Incomplete")
        XCTAssertNotEqual(model.statusText(for: profile.id), "In Use")

        await credentials.set("credential-fixture", for: profile.id)
        await model.refreshCredentialPresence(profileID: profile.id)
        await model.validate(profileID: profile.id)

        XCTAssertEqual(model.statusText(for: profile.id), "In Use")
        XCTAssertEqual(model.accessibilityEvent?.message, "Provider test passed.")
        let validatedProfileIDs = await validation.validatedProfileIDs()
        XCTAssertEqual(validatedProfileIDs, [profile.id])
        let clearedCredentialFlags = await validation.retainedCredentialEmptyFlags()
        XCTAssertEqual(clearedCredentialFlags, [true])
        XCTAssertTrue(
            model.canUse(
                OutputMode(id: UUID(), title: "Polish", skipsPolishing: false, instructions: "Fix it")
            )
        )
    }

    func testKeylessLoopbackCanValidateButKeylessHTTPSCannot() async {
        let loopback = ProviderProfile(
            id: UUID(),
            title: "Local",
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            modelID: "local-model",
            policy: .loopbackHTTP
        )
        let remote = providerProfile()
        var settings = UserSettings.p0Default
        settings.providerProfiles = [loopback, remote]
        settings.selectedProviderProfileID = loopback.id
        let validation = ProviderValidationFake(
            result: .ready(normalizedHost: "127.0.0.1:11434", modelID: "local-model")
        )
        let model = ProviderSettingsViewModel(
            settings: AppSettingsFake(value: settings),
            credentials: ProviderCredentialFake(),
            migration: ProviderMigrationFake(),
            validation: validation
        )

        await model.load()
        await model.validate(profileID: loopback.id)
        XCTAssertEqual(model.statusText(for: loopback.id), "In Use")
        let emptyFlags = await validation.credentialEmptyFlags()
        XCTAssertEqual(emptyFlags, [true])

        await model.validate(profileID: remote.id)
        XCTAssertEqual(model.statusText(for: remote.id), "Incomplete")
        let validatedIDs = await validation.validatedProfileIDs()
        XCTAssertEqual(validatedIDs, [loopback.id])
    }

    func testModelEditInvalidatesReadySelectionAndEndpointEditUsesFreshCredentialID() async throws {
        let profile = providerProfile()
        var settings = UserSettings.p0Default
        settings.providerProfiles = [profile]
        settings.selectedProviderProfileID = profile.id
        let store = AppSettingsFake(value: settings)
        let credentials = ProviderCredentialFake(values: [profile.id: "old-credential"])
        let validation = ProviderValidationFake(
            result: .ready(normalizedHost: "api.example.test", modelID: "model-a")
        )
        let model = ProviderSettingsViewModel(
            settings: store,
            credentials: credentials,
            migration: ProviderMigrationFake(),
            validation: validation
        )

        await model.load()
        await model.validate(profileID: profile.id)
        XCTAssertEqual(model.statusText(for: profile.id), "In Use")

        let modelEditSaved = await model.updateProfile(
            id: profile.id,
            templateID: .custom,
            title: profile.title,
            baseURL: profile.baseURL.absoluteString,
            modelID: "model-b",
            credential: "",
            allowsLoopbackHTTP: false
        )
        XCTAssertTrue(modelEditSaved)
        var saved = try await store.current()
        XCTAssertNil(saved.selectedProviderProfileID)
        XCTAssertEqual(saved.providerProfiles[0].id, profile.id)
        XCTAssertEqual(model.statusText(for: profile.id), "Not Tested")

        let endpointEditSaved = await model.updateProfile(
            id: profile.id,
            templateID: .custom,
            title: profile.title,
            baseURL: "https://other.example.test/v1",
            modelID: "model-c",
            credential: "new-credential",
            allowsLoopbackHTTP: false
        )
        XCTAssertTrue(endpointEditSaved)
        saved = try await store.current()
        let replacementID = try XCTUnwrap(saved.providerProfiles.first?.id)
        XCTAssertNotEqual(replacementID, profile.id)
        XCTAssertNil(saved.selectedProviderProfileID)
        let storedIDs = await credentials.storedProfileIDs()
        XCTAssertEqual(storedIDs, [replacementID])
    }

    func testDisclosureUsesOnlyNormalizedHostAndMatchesApprovedCopy() async {
        let profile = providerProfile(baseURL: "https://API.Example.Test/v1/")
        var settings = UserSettings.p0Default
        settings.providerProfiles = [profile]
        settings.selectedProviderProfileID = profile.id
        let model = ProviderSettingsViewModel(
            settings: AppSettingsFake(value: settings),
            credentials: ProviderCredentialFake(),
            migration: ProviderMigrationFake(),
            validation: ProviderValidationFake()
        )

        await model.load()

        XCTAssertEqual(
            model.egressDisclosure(forCandidate: "https://API.Example.Test/private/path"),
            "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to api.example.test."
        )
        XCTAssertNil(
            model.egressDisclosure(forCandidate: "https://api.example.test/private?query=secret")
        )

        XCTAssertEqual(
            model.egressDisclosure,
            "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to api.example.test."
        )
        XCTAssertFalse(model.egressDisclosure?.contains("/v1") ?? true)
    }

    func testCustomHTTPRejectsLANAndRequiresExplicitLoopbackOptIn() async throws {
        let store = AppSettingsFake()
        let model = ProviderSettingsViewModel(
            settings: store,
            credentials: ProviderCredentialFake(),
            migration: ProviderMigrationFake(),
            validation: ProviderValidationFake()
        )
        await model.load()

        let lanSaved = await model.addProfile(
            templateID: .custom,
            title: "LAN",
            baseURL: "http://192.168.1.10:11434/v1",
            modelID: "local-model",
            credential: "",
            allowsLoopbackHTTP: true
        )
        let loopbackWithoutOptInSaved = await model.addProfile(
            templateID: .custom,
            title: "Loopback",
            baseURL: "http://127.0.0.1:11434/v1",
            modelID: "local-model",
            credential: "",
            allowsLoopbackHTTP: false
        )
        XCTAssertFalse(lanSaved)
        XCTAssertFalse(loopbackWithoutOptInSaved)
        XCTAssertTrue(ProviderSettingsViewModel.loopbackOptInLabel.lowercased().contains("loopback"))
        let loopbackSaved = await model.addProfile(
            templateID: .custom,
            title: "Loopback",
            baseURL: "http://127.0.0.1:11434/v1",
            modelID: "local-model",
            credential: "",
            allowsLoopbackHTTP: true
        )
        XCTAssertTrue(loopbackSaved)
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Provider profile added. Test it before selecting it."
        )

        let saved = try await store.current()
        XCTAssertEqual(saved.providerProfiles.count, 1)
        XCTAssertEqual(saved.providerProfiles[0].policy, .loopbackHTTP)
    }

    func testHostedTemplatesAreRescuedExactlyAndCustomIsLast() {
        XCTAssertEqual(
            ProviderTemplate.all.map(\.title),
            [
                "OpenRouter", "OpenAI", "Groq", "Together AI", "MiniMax (China)",
                "MiniMax (Global)", "DeepSeek", "Moonshot", "SiliconFlow",
                "Alibaba Qwen (DashScope)", "Zhipu GLM", "Google (Gemini)",
                "Volcano Engine (Ark)", "Custom",
            ]
        )
        XCTAssertEqual(ProviderTemplate.all.filter { $0.id != .custom }.count, 13)
        XCTAssertNil(ProviderTemplate.all.last?.fixedBaseURL)
        XCTAssertEqual(
            ProviderTemplate.all.map(\.fixedBaseURL),
            [
                "https://openrouter.ai/api/v1",
                "https://api.openai.com/v1",
                "https://api.groq.com/openai/v1",
                "https://api.together.xyz/v1",
                "https://api.minimaxi.com/v1",
                "https://api.minimax.io/v1",
                "https://api.deepseek.com/v1",
                "https://api.moonshot.cn/v1",
                "https://api.siliconflow.cn/v1",
                "https://dashscope.aliyuncs.com/compatible-mode/v1",
                "https://open.bigmodel.cn/api/paas/v4",
                "https://generativelanguage.googleapis.com/v1beta/openai",
                "https://ark.cn-beijing.volces.com/api/v3",
                nil,
            ]
        )
        XCTAssertEqual(
            ProviderTemplate.all.map(\.defaultModelID),
            [
                "openrouter/free", "gpt-4o-mini", "llama-3.3-70b-versatile",
                "meta-llama/Llama-3.1-8B-Instruct-Turbo", "MiniMax-M2.7",
                "MiniMax-M2.7", "deepseek-chat", "moonshot-v1-8k",
                "Qwen/Qwen2.5-7B-Instruct", "qwen-turbo", "glm-4-flash",
                "gemini-2.0-flash", "doubao-pro-32k", "default",
            ]
        )
    }

    func testMigrationConflictOffersExactValueFreeChoices() async {
        let profile = providerProfile()
        var settings = UserSettings.p0Default
        settings.providerProfiles = [profile]
        let migration = ProviderMigrationFake(result: .conflict)
        let model = ProviderSettingsViewModel(
            settings: AppSettingsFake(value: settings),
            credentials: ProviderCredentialFake(),
            migration: migration,
            validation: ProviderValidationFake()
        )

        await model.load()
        XCTAssertEqual(model.migrationMessage(for: profile.id), "A legacy credential conflicts with the secure Keychain item. Choose which secure result to keep.")
        XCTAssertEqual(model.conflictChoices(for: profile.id), [.keepSecure, .replaceSecureWithLegacy])

        await model.resolveConflict(profileID: profile.id, choice: .keepSecure)
        await model.resolveConflict(profileID: profile.id, choice: .replaceSecureWithLegacy)

        let resolvedChoices = await migration.resolvedChoices()
        XCTAssertEqual(resolvedChoices, [.keepSecure, .replaceSecureWithLegacy])
        let copy = model.migrationMessage(for: profile.id) ?? ""
        XCTAssertFalse(copy.contains("credential-fixture"))
        XCTAssertFalse(copy.contains("sk-"))
        XCTAssertEqual(
            model.accessibilityEvent?.message,
            "Credential migration still needs attention."
        )
    }

    func testDiagnosticsPreviewIsAllowlistedAndContainsNoCanarySensitiveValues() {
        let exporter = SafeDiagnosticsExporter()
        let model = DiagnosticsSettingsViewModel(exporter: exporter)
        let summary = SafeDiagnosticsSummary(
            lastStage: .polishing,
            diagnosticCodes: [.polishTransport],
            eventCounts: [DiagnosticEventCount(component: .polishing, count: 1)]
        )
        let snapshot = DiagnosticsSnapshot(
            appVersion: "1.0",
            appBuild: "1",
            operatingSystemVersion: "15.5",
            architecture: .arm64,
            microphonePermission: .granted,
            accessibilityPermission: .granted,
            speechModelID: "sk-canary-transcript-path-query",
            speechModelPhase: .ready,
            providerHost: "api.example.test/private/path?query=canary-query",
            providerModelID: "secret-canary-prompt-key-path-query",
            historyEnabled: true,
            historyItemCount: 1,
            summary: summary
        )

        model.preparePreview(snapshot)

        let preview = model.preview
        XCTAssertTrue(model.canExport)
        for canary in ["canary-transcript", "canary-query", "canary-prompt", "private/path", "sk-canary"] {
            XCTAssertFalse(preview.contains(canary), "preview leaked \(canary)")
        }
        XCTAssertTrue(preview.contains("\"schemaVersion\""))
        XCTAssertTrue(preview.contains("redacted-invalid-model-id"))
        XCTAssertTrue(preview.contains("redacted-invalid-host"))
    }

    func testDiagnosticsExportResultReportsOnlySanitizedStatus() {
        let model = DiagnosticsSettingsViewModel(exporter: SafeDiagnosticsExporter())

        model.recordExportResult(
            .failure(
                NSError(
                    domain: "canary-private-export-path",
                    code: 17,
                    userInfo: [NSLocalizedDescriptionKey: "canary-system-error"]
                )
            )
        )

        XCTAssertEqual(
            model.failureMessage,
            "Diagnostics could not be exported. No file path or system error details were retained."
        )
        XCTAssertNil(model.exportStatusMessage)
        XCTAssertFalse(model.failureMessage?.contains("canary") ?? true)

        model.recordExportResult(
            .success(URL(fileURLWithPath: "/private/canary-export-location.json"))
        )

        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(model.exportStatusMessage, "Diagnostics exported.")
        XCTAssertFalse(model.exportStatusMessage?.contains("canary") ?? true)
    }

    func testLiveDiagnosticsIncludesStableWarningCodeButNeverCompletedResultText() async throws {
        let controller = RecordingIntentControllerSpy()
        let sessionID = SessionID()
        controller.state = PipelineState(
            stage: .completed,
            sessionID: sessionID,
            token: EffectToken(sessionID: sessionID, generation: 1),
            result: DictationResult(
                sessionID: sessionID,
                rawText: "canary-live-transcript",
                finalText: "canary-live-polished-result",
                source: .rawFallback,
                warning: .polishTransport,
                delivery: nil
            ),
            failure: nil
        )
        let snapshot = try await DiagnosticsSettingsViewModel.liveSnapshot(
            settings: AppSettingsFake(),
            controller: controller,
            permissions: AppPermissionFake()
        )
        let model = DiagnosticsSettingsViewModel(exporter: SafeDiagnosticsExporter())

        model.preparePreview(snapshot)

        XCTAssertTrue(model.preview.contains("polish.transport"))
        XCTAssertFalse(model.preview.contains("canary-live-transcript"))
        XCTAssertFalse(model.preview.contains("canary-live-polished-result"))
    }
}

private func providerProfile(
    id: UUID = UUID(),
    baseURL: String = "https://api.example.test/v1"
) -> ProviderProfile {
    ProviderProfile(
        id: id,
        title: "Example",
        baseURL: URL(string: baseURL)!,
        modelID: "model-a",
        policy: .remoteHTTPS
    )
}

private actor ProviderCredentialFake: CredentialStore {
    private var values: [UUID: String]

    init(values: [UUID: String] = [:]) {
        self.values = values
    }

    func set(_ value: String, for profileID: UUID) {
        values[profileID] = value
    }

    func read(profileID: UUID) async throws -> SessionSecret? {
        values[profileID].map(SessionSecret.init(utf8:))
    }

    func write(_ secret: SessionSecret, profileID: UUID) async throws {
        values[profileID] = try secret.withUTF8 { $0 }
    }

    func delete(profileID: UUID) async throws {
        values[profileID] = nil
    }

    func storedProfileIDs() -> [UUID] {
        values.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

private actor ProviderMigrationFake: CredentialMigrationService {
    var result: CredentialMigrationResult
    private var choices: [CredentialConflictChoice] = []

    init(result: CredentialMigrationResult = .noLegacyValue) {
        self.result = result
    }

    func migrate(profileID: UUID) async -> CredentialMigrationResult { result }

    func resolve(
        profileID: UUID,
        choice: CredentialConflictChoice
    ) async -> CredentialMigrationResult {
        choices.append(choice)
        return result
    }

    func resolvedChoices() -> [CredentialConflictChoice] { choices }
}

private actor ProviderValidationFake: ProviderValidationService {
    var result: ProviderValidationResult
    private var profileIDs: [UUID] = []
    private var emptyFlags: [Bool] = []
    private var retainedCredentials: [SessionSecret] = []

    init(result: ProviderValidationResult = .failed(.credentialMissing)) {
        self.result = result
    }

    func validate(
        profile: ProviderProfile,
        credential: SessionSecret
    ) async -> ProviderValidationResult {
        profileIDs.append(profile.id)
        emptyFlags.append((try? credential.withUTF8 { $0.isEmpty }) ?? false)
        retainedCredentials.append(credential)
        return result
    }

    func validatedProfileIDs() -> [UUID] { profileIDs }
    func credentialEmptyFlags() -> [Bool] { emptyFlags }
    func retainedCredentialEmptyFlags() -> [Bool] {
        retainedCredentials.map { (try? $0.withUTF8 { $0.isEmpty }) ?? false }
    }
}
