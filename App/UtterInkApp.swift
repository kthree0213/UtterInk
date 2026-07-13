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
            Text(model.readiness == .failed ? "Unavailable" : model.pipeline.stage.rawValue)
            Divider()
            Button(model.pipeline.stage == .recording ? "Stop" : "Start") {
                model.startOrStop()
            }
            .disabled(model.readiness != .ready)

            Button("Cancel") {
                model.cancel()
            }
            .disabled(model.readiness != .ready)

            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }

        Settings {
            VStack(alignment: .leading, spacing: 8) {
                Text("UtterInk Settings")
                    .font(.headline)
                Text(
                    model.readiness == .failed
                        ? "Pipeline: Unavailable"
                        : "Pipeline: \(model.pipeline.stage.rawValue)"
                )
            }
            .padding(24)
        }
    }
}

@MainActor
private final class InertAppController: DictationControlling {
    var state: PipelineState = .idle
    var speechModelState: SpeechModelState = .missing(modelID: "small")
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext?
    var speechModelCatalog: [SpeechModelDescriptor] = []

    func bootstrap() async {}
    func send(_ intent: UserIntent) {}
    func prepareSpeechModel(_ modelID: String) {}
    func cancelSpeechModelPreparation() {}
    func deleteCachedSpeechModel(_ modelID: String) {}
}
