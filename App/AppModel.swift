import Foundation
import Observation
import UtterInkCore

enum AppReadiness: Equatable {
    case pending
    case ready
    case failed
}

@MainActor
@Observable
final class AppModel {
    typealias StartupPreparation = @MainActor () async throws -> Void
    typealias PostBootstrapVerification = @MainActor () async throws -> Void

    let controller: any DictationControlling
    private(set) var readiness: AppReadiness = .pending

    @ObservationIgnored private let startupPreparation: StartupPreparation
    @ObservationIgnored private let postBootstrapVerification: PostBootstrapVerification
    @ObservationIgnored private let bootstrapEnabled: Bool
    @ObservationIgnored private var bootstrapTask: Task<Bool, Never>?
    @ObservationIgnored private var bootstrapGeneration: UUID?

    init(
        controller: any DictationControlling,
        startupPreparation: @escaping StartupPreparation = {},
        postBootstrapVerification: @escaping PostBootstrapVerification = {},
        initialReadiness: AppReadiness = .pending,
        bootstrapEnabled: Bool = true
    ) {
        self.controller = controller
        self.startupPreparation = startupPreparation
        self.postBootstrapVerification = postBootstrapVerification
        self.readiness = initialReadiness
        self.bootstrapEnabled = bootstrapEnabled
    }

    static func unavailable(controller: any DictationControlling) -> AppModel {
        AppModel(
            controller: controller,
            initialReadiness: .failed,
            bootstrapEnabled: false
        )
    }

    var pipeline: PipelineState { controller.state }
    var speechModel: SpeechModelState { controller.speechModelState }
    var volatileResults: [DictationResult] { controller.volatileResults }
    var historyRecords: [HistoryRecord] { controller.historyRecords }
    var recordingTelemetry: RecordingTelemetry? { controller.recordingTelemetry }
    var sessionPresentation: SessionPresentationContext? { controller.sessionPresentation }
    var speechModelCatalog: [SpeechModelDescriptor] { controller.speechModelCatalog }

    func bootstrap() async {
        guard bootstrapEnabled else { return }
        if readiness == .ready { return }
        if let bootstrapTask {
            _ = await bootstrapTask.value
            return
        }

        let generation = UUID()
        bootstrapGeneration = generation
        let startupPreparation = startupPreparation
        let postBootstrapVerification = postBootstrapVerification
        let controller = controller
        let task = Task { @MainActor in
            do {
                try await startupPreparation()
                await controller.bootstrap()
                try await postBootstrapVerification()
                return true
            } catch {
                return false
            }
        }
        bootstrapTask = task

        let succeeded = await task.value
        guard bootstrapGeneration == generation else { return }
        bootstrapTask = nil
        bootstrapGeneration = nil
        readiness = succeeded ? .ready : .failed
    }

    func startOrStop() {
        guard readiness == .ready else { return }
        switch pipeline.stage {
        case .recording:
            controller.send(.stop)
        case .idle, .completed, .failed:
            controller.send(.start(.focusedExternal))
        default:
            break
        }
    }

    func start() {
        guard readiness == .ready else { return }
        switch pipeline.stage {
        case .idle, .completed, .failed:
            controller.send(.start(.focusedExternal))
        default:
            break
        }
    }

    func stop() {
        guard readiness == .ready, pipeline.stage == .recording else { return }
        controller.send(.stop)
    }

    func cancel() {
        guard readiness == .ready else { return }
        controller.send(.cancel)
    }
}
