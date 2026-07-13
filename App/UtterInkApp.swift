import SwiftUI
import UtterInkCore

@main
struct UtterInkApp: App {
    private let composition: AppComposition?
    @State private var model: AppModel

    @MainActor
    init() {
        self.init(
            isHostedUnitTest:
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
            compositionFactory: AppComposition.live
        )
    }

    @MainActor
    init(
        isHostedUnitTest: Bool,
        compositionFactory: @MainActor () throws -> AppComposition
    ) {
        if isHostedUnitTest {
            composition = nil
            _model = State(initialValue: AppModel(controller: InertAppController()))
            return
        }

        let composition: AppComposition
        do {
            composition = try compositionFactory()
        } catch {
            self.composition = nil
            _model = State(
                initialValue: AppModel.unavailable(controller: InertAppController())
            )
            return
        }
        self.composition = composition
        _model = State(initialValue: composition.model)

        Task { @MainActor [composition] in
            await composition.start()
        }
    }

    var usesLiveComposition: Bool { composition != nil }
    var readinessForTests: AppReadiness { model.readiness }

    var body: some Scene {
        MenuBarExtra(ProductIdentity.name, systemImage: "text.cursor") {
            MenuBarRootView(
                model: model,
                settingsStore: composition?.features.settings
            )
        }

        Window(EnglishCopy.latestResult, id: AppWindowID.lastResult) {
            LastResultView(
                model: HistoryViewModel(controller: model.controller)
            )
            .frame(minWidth: 420, minHeight: 280)
        }
        .defaultSize(width: 520, height: 420)

        Window(EnglishCopy.history, id: AppWindowID.history) {
            HistoryView(
                model: HistoryViewModel(controller: model.controller)
            )
            .frame(minWidth: 620, minHeight: 420)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            if let settingsModel = composition?.settingsModel {
                SettingsRootView(model: settingsModel)
            } else {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "exclamationmark.triangle.fill",
                    description: Text("Quit and reopen UtterInk to try again.")
                )
            }
        }
    }
}

@MainActor
private final class InertAppController: DictationControlling {
    var state: PipelineState = .idle
    var speechModelState: SpeechModelState = .missing(modelID: "small")
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var historyControlStatus: HistoryControlStatus = .settled(enabled: true)
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext?
    var speechModelCatalog: [SpeechModelDescriptor] = []

    func bootstrap() async {}
    func send(_ intent: UserIntent) {}
    func prepareSpeechModel(_ modelID: String) {}
    func cancelSpeechModelPreparation() {}
    func deleteCachedSpeechModel(_ modelID: String) {}
}
