import Foundation
import XCTest
import UtterInkCore
import UtterInkServices

final class ExternalConstructionTests: XCTestCase {
    func testBundledAuthoritiesDoNotDependOnRepositoryWorkingDirectory() throws {
        let manager = FileManager.default
        let original = manager.currentDirectoryPath
        let empty = manager.temporaryDirectory
            .appendingPathComponent("utterink-external-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        defer {
            _ = manager.changeCurrentDirectoryPath(original)
            try? manager.removeItem(at: empty)
        }
        XCTAssertTrue(manager.changeCurrentDirectoryPath(empty.path))

        let defaults = LegacyDefaultsMap.bundled
        let models = WhisperModelCatalog.bundled

        XCTAssertEqual(defaults.authorityHash.count, 64)
        XCTAssertFalse(defaults.entries.isEmpty)
        XCTAssertEqual(Set(models.descriptors.map(\.id)), ["base", "small", "large-v3"])
        XCTAssertTrue(models.descriptors.allSatisfy { $0.approximateBytes > 0 })
    }
}

// These functions are deliberately never invoked. Compiling their bodies from
// an ordinary consumer target proves every production construction entry point
// is public and has the exact implementation-index signature.
private enum PublicFactories {
    static func clock() -> SystemAppClock {
        SystemAppClock()
    }

    static func history(directory: URL, clock: any AppClock) throws -> JSONHistoryStore {
        try JSONHistoryStore(directory: directory, enabled: true, clock: clock)
    }

    static func settings(defaults: UserDefaults) throws -> UserDefaultsSettingsStore {
        try UserDefaultsSettingsStore(defaults: defaults, legacyMap: .bundled)
    }

    static func legacyReader() throws -> LegacyDefaultsReader {
        try LegacyDefaultsReader(suiteName: "dev.flowtype.FlowType")
    }

    static func keychain() -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: "dev.utterink.UtterInk.provider-credentials",
            accessGroup: nil
        )
    }

    static func migrator(
        legacy: LegacyDefaultsReader,
        credentials: any CredentialStore
    ) throws -> LegacyCredentialMigrator {
        try LegacyCredentialMigrator(
            legacy: legacy,
            credentials: credentials,
            map: .bundled
        )
    }

    static func audioStore(root: URL, clock: any AppClock) throws -> TransientAudioStore {
        try TransientAudioStore(root: root, clock: clock)
    }

    static func audio(store: TransientAudioStore) -> AVAudioRecordingService {
        AVAudioRecordingService(store: store)
    }

    static func catalog(data: Data) throws -> WhisperModelCatalog {
        try WhisperModelCatalog(data: data)
    }

    static func models(
        catalog: WhisperModelCatalog,
        root: URL,
        clock: any AppClock
    ) throws -> WhisperModelService {
        try WhisperModelService(catalog: catalog, root: root, clock: clock)
    }

    static func transcription(models: WhisperModelService) -> WhisperTranscriber {
        WhisperTranscriber(models: models)
    }

    static func polishing(clock: any AppClock) -> OpenAICompatibleClient {
        OpenAICompatibleClient(clock: clock)
    }

    static func onboarding() -> InMemoryOnboardingTestSink {
        InMemoryOnboardingTestSink()
    }

    @MainActor
    static func target(clock: any AppClock) -> TargetTracker {
        TargetTracker(clock: clock)
    }

    @MainActor
    static func pasteboard(clock: any AppClock) -> PasteboardClient {
        PasteboardClient(clock: clock)
    }

    @MainActor
    static func delivery(
        pasteboard: PasteboardClient,
        target: TargetTracker,
        onboarding: any OnboardingTestSink,
        clock: any AppClock
    ) -> DeliveryCoordinator {
        DeliveryCoordinator(
            pasteboard: pasteboard,
            target: target,
            onboardingSink: onboarding,
            clock: clock,
            settleDelay: .milliseconds(250)
        )
    }

    static func permissions() -> SystemPermissionService {
        SystemPermissionService()
    }

    @MainActor
    static func hotkey() -> KeyboardShortcutsHotkeyService {
        KeyboardShortcutsHotkeyService(mode: .toggle) { _ in }
    }

    static func diagnostics() -> SafeDiagnosticsSink {
        SafeDiagnosticsSink()
    }

    static func exporter() -> DiagnosticsExporter {
        DiagnosticsExporter()
    }

    @MainActor
    static func controller(
        settings: any SettingsStore,
        target: any TargetSnapshotService,
        permissions: any PermissionService,
        history: any HistoryStore,
        credentials: any CredentialStore,
        audio: any AudioRecordingService,
        models: any SpeechModelService,
        transcription: any TranscriptionService,
        polishing: any PolishingService,
        delivery: any DeliveryService,
        diagnostics: any DiagnosticsSink,
        modelCatalog: [SpeechModelDescriptor],
        clock: any AppClock
    ) -> DictationSessionController {
        DictationSessionController(
            settings: settings,
            target: target,
            permissions: permissions,
            history: history,
            credentials: credentials,
            audio: audio,
            models: models,
            transcription: transcription,
            polishing: polishing,
            delivery: delivery,
            diagnostics: diagnostics,
            modelCatalog: modelCatalog,
            clock: clock
        )
    }
}
