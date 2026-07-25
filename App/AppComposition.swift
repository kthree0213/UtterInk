import Foundation
import UtterInkCore
import UtterInkServices

struct AppFeatureDependencies {
    let settings: any SettingsStore
    let permissions: any PermissionService
    let systemSettings: any SystemSettingsNavigating
    let launchAtLogin: any LaunchAtLoginManaging
    let hotkeyProbe: any HotkeyProbing
    let hotkeyConfiguration: any HotkeyConfiguring
    let credentials: any CredentialStore
    let credentialMigration: any CredentialMigrationService
    let providerValidation: any ProviderValidationService
    let diagnosticsExport: any DiagnosticsExporting
    let onboardingSink: any OnboardingTestSink
    let clock: any AppClock
}

@MainActor
final class AppComposition {
    let model: AppModel
    let features: AppFeatureDependencies
    let floatingWindowController: FloatingWindowController?
    let settingsModel: SettingsRootModel
    let onboardingModel: OnboardingViewModel

    private var hotkeyListenerTask: Task<Void, Never>?
    private var hotkeyArmTask: Task<AsyncStream<Void>, Never>?
    private var didEvaluateAutomaticOnboarding = false
    private let automaticallyShowsOnboarding: Bool
    private lazy var onboardingWindowController = OnboardingWindowController(
        model: onboardingModel
    )

    init(
        model: AppModel,
        features: AppFeatureDependencies,
        floatingWindowController: FloatingWindowController? = nil,
        automaticallyShowsOnboarding: Bool = false
    ) {
        self.model = model
        self.features = features
        self.floatingWindowController = floatingWindowController
        self.automaticallyShowsOnboarding = automaticallyShowsOnboarding
        self.settingsModel = SettingsRootModel(
            dependencies: features,
            controller: model.controller,
            setFloatingRecorderEnabled: { [weak floatingWindowController] enabled in
                floatingWindowController?.setEnabled(enabled)
            }
        )
        self.onboardingModel = OnboardingViewModel(
            settings: features.settings,
            controller: model.controller,
            permissions: features.permissions,
            hotkeyProbe: features.hotkeyProbe,
            onboardingSink: features.onboardingSink,
            systemSettings: features.systemSettings
        )
        self.settingsModel.general.setReplayOnboardingHandler { [weak self] in
            self?.replayOnboarding()
        }
    }

    static func live() throws -> AppComposition {
        let clock = SystemAppClock()
        let settings = try UserDefaultsSettingsStore(defaults: .standard)
        let credentials = KeychainCredentialStore()
        let legacyDefaults = try LegacyDefaultsReader(suiteName: "dev.flowtype.FlowType")
        let credentialMigration = try LegacyCredentialMigrator(
            legacy: legacyDefaults,
            credentials: credentials
        )

        let applicationSupport = try applicationSupportRoot()
        let history = try JSONHistoryStore(
            directory: applicationSupport,
            enabled: true,
            clock: clock
        )
        let transientAudio = try TransientAudioStore(
            root: applicationSupport.appendingPathComponent("TransientAudio", isDirectory: true),
            clock: clock
        )
        let recorder = AVAudioRecordingService(store: transientAudio)

        let modelCatalog = WhisperModelCatalog.bundled
        let speechModels = try WhisperModelService(
            catalog: modelCatalog,
            root: applicationSupport.appendingPathComponent("huggingface", isDirectory: true),
            clock: clock
        )
        let transcriber = WhisperTranscriber(models: speechModels)

        let permissions = SystemPermissionService()
        let target = TargetTracker(clock: clock)
        let pasteboard = PasteboardClient(clock: clock)
        let onboardingSink = InMemoryOnboardingTestSink()
        let delivery = DeliveryCoordinator(
            pasteboard: pasteboard,
            target: target,
            onboardingSink: onboardingSink,
            clock: clock
        )
        let providerClient = OpenAICompatibleClient(clock: clock)
        let diagnostics = SafeDiagnosticsSink()

        let controller = DictationSessionController(
            settings: settings,
            target: target,
            permissions: permissions,
            history: history,
            credentials: credentials,
            audio: recorder,
            models: speechModels,
            transcription: transcriber,
            polishing: providerClient,
            delivery: delivery,
            diagnostics: diagnostics,
            modelCatalog: modelCatalog.descriptors,
            clock: clock
        )

        let model = AppModel(
            controller: controller,
            startupPreparation: {
                try await transientAudio.sweep()
                let currentSettings = try await settings.current()
                _ = try await history.setEnabled(currentSettings.historyEnabled)
                for profile in currentSettings.providerProfiles {
                    _ = await credentialMigration.migrate(profileID: profile.id)
                }
            },
            postBootstrapVerification: {
                _ = try await settings.current()
                _ = try await history.load()
            }
        )
        let hotkey = LazyHotkeyService(settings: settings) { [weak model] mode, event in
            switch mode {
            case .toggle:
                // The service event is a physical-key latch, not recording state.
                // Resolve every accepted press against the controller's current stage.
                model?.handleToggleHotkey()
            case .holdToTalk:
                switch event {
                case .startRequested:
                    model?.start()
                case .stopRequested:
                    model?.releaseHoldToTalk()
                }
            }
        }

        let features = AppFeatureDependencies(
            settings: settings,
            permissions: permissions,
            systemSettings: SystemSettingsNavigator(),
            launchAtLogin: LaunchAtLoginService(),
            hotkeyProbe: hotkey,
            hotkeyConfiguration: hotkey,
            credentials: credentials,
            credentialMigration: credentialMigration,
            providerValidation: providerClient,
            diagnosticsExport: SafeDiagnosticsExporter(),
            onboardingSink: onboardingSink,
            clock: clock
        )
        return AppComposition(
            model: model,
            features: features,
            floatingWindowController: FloatingWindowController(model: model, clock: clock),
            automaticallyShowsOnboarding: true
        )
    }

#if DEBUG
    static func uiTest(scenario: UITestScenario) -> AppComposition {
        UITestCompositionFactory.make(scenario: scenario)
    }
#endif

    func start() async {
        await model.bootstrap()
        guard model.readiness == .ready else { return }

        if let floatingWindowController {
            let showFloatingRecorder = (try? await features.settings.current())?
                .showFloatingRecorder ?? false
            floatingWindowController.start(isEnabled: showFloatingRecorder)
        }

        if automaticallyShowsOnboarding, !didEvaluateAutomaticOnboarding {
            didEvaluateAutomaticOnboarding = true
            await onboardingWindowController.showIfNeeded()
        }
        if hotkeyListenerTask != nil { return }

        let events: AsyncStream<Void>
        if let hotkeyArmTask {
            events = await hotkeyArmTask.value
        } else {
            let hotkeyProbe = features.hotkeyProbe
            let task = Task { @MainActor in
                await hotkeyProbe.arm()
            }
            hotkeyArmTask = task
            events = await task.value
            hotkeyArmTask = nil
        }

        guard hotkeyListenerTask == nil else { return }
        hotkeyListenerTask = Task {
            for await _ in events {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func showOnboarding() {
        onboardingWindowController.show()
    }

    func replayOnboarding() {
        onboardingWindowController.showFromBeginning()
    }

    private static func applicationSupportRoot() throws -> URL {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return root.appendingPathComponent("UtterInk", isDirectory: true)
    }
}
