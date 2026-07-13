import OSLog
import UtterInkCore

public actor SafeLogger {
    private enum SafeLogEvent {
        case stage(PipelineStage)
        case serviceFailure(DiagnosticComponent, DiagnosticCode)
        case model(DiagnosticModelPhase)
    }

    private let logger = Logger(subsystem: "dev.utterink.UtterInk", category: "diagnostics")
    private var events: [SafeLogEvent] = []
    private let maximumCapturedEvents = 256

    public init() {}

    public func stageChanged(_ stage: PipelineStage) {
        emit(.stage(stage))
    }

    public func serviceFailed(component: DiagnosticComponent, code: DiagnosticCode) {
        emit(.serviceFailure(component, code))
    }

    public func modelStateChanged(catalogIndex: Int, phase: DiagnosticModelPhase) {
        guard (0..<256).contains(catalogIndex) else { return }
        emit(.model(phase))
    }

    func capturedMessages() -> [String] {
        events.flatMap(Self.messages)
    }

    private func emit(_ event: SafeLogEvent) {
        if events.count == maximumCapturedEvents {
            events.removeFirst()
        }
        events.append(event)
        switch event {
        case let .stage(stage):
            logStage(stage)
        case let .serviceFailure(component, code):
            logComponent(component)
            logCode(code)
        case let .model(phase):
            logModel(phase)
        }
    }

    private func logStage(_ stage: PipelineStage) {
        switch stage {
        case .idle: logger.notice("Pipeline entered idle.")
        case .requestingPermission: logger.notice("Pipeline requested permission.")
        case .recording: logger.notice("Pipeline started recording.")
        case .stopping: logger.notice("Pipeline started stopping.")
        case .transcribing: logger.notice("Pipeline started transcription.")
        case .polishing: logger.notice("Pipeline started polishing.")
        case .delivering: logger.notice("Pipeline started delivery.")
        case .completed: logger.notice("Pipeline completed.")
        case .failed: logger.notice("Pipeline failed.")
        }
    }

    private func logComponent(_ component: DiagnosticComponent) {
        switch component {
        case .audio: logger.notice("Audio service failed.")
        case .speechModel: logger.notice("Speech model service failed.")
        case .transcription: logger.notice("Transcription service failed.")
        case .history: logger.notice("History service failed.")
        case .credential: logger.notice("Credential service failed.")
        case .polishing: logger.notice("Polishing service failed.")
        case .delivery: logger.notice("Delivery service failed.")
        case .permissions: logger.notice("Permission service failed.")
        }
    }

    private func logCode(_ code: DiagnosticCode) {
        switch code {
        case .permissionMicrophone: logger.notice("Code permission microphone.")
        case .permissionAccessibility: logger.notice("Code permission accessibility.")
        case .audioStart: logger.notice("Code audio start.")
        case .audioFinalize: logger.notice("Code audio finalize.")
        case .transcriptionEmpty: logger.notice("Code transcription empty.")
        case .transcriptionFailed: logger.notice("Code transcription failed.")
        case .historyWrite: logger.notice("Code history write.")
        case .historyCorrupt: logger.notice("Code history corrupt.")
        case .credentialMissing: logger.notice("Code credential missing.")
        case .credentialMigrationConflict: logger.notice("Code credential migration conflict.")
        case .polishTransport: logger.notice("Code polish transport.")
        case .polishAuthentication: logger.notice("Code polish authentication.")
        case .polishInvalidResponse: logger.notice("Code polish invalid response.")
        case .deliveryTargetUnavailable: logger.notice("Code delivery target unavailable.")
        case .deliveryTargetChanged: logger.notice("Code delivery target changed.")
        case .deliveryPasteboardChanged: logger.notice("Code delivery pasteboard changed.")
        case .deliveryDispatch: logger.notice("Code delivery dispatch.")
        case .cancelled: logger.notice("Code session cancelled.")
        }
    }

    private func logModel(_ phase: DiagnosticModelPhase) {
        switch phase {
        case .missing: logger.notice("Speech model is missing.")
        case .downloading: logger.notice("Speech model is downloading.")
        case .loading: logger.notice("Speech model is loading.")
        case .ready: logger.notice("Speech model is ready.")
        case .failed: logger.notice("Speech model failed.")
        }
    }

    private static func messages(_ event: SafeLogEvent) -> [String] {
        switch event {
        case let .stage(stage):
            return [stageMessage(stage)]
        case let .serviceFailure(component, code):
            return [componentMessage(component), codeMessage(code)]
        case let .model(phase):
            return [modelMessage(phase)]
        }
    }

    private static func stageMessage(_ stage: PipelineStage) -> String {
        switch stage {
        case .idle: return "Pipeline entered idle."
        case .requestingPermission: return "Pipeline requested permission."
        case .recording: return "Pipeline started recording."
        case .stopping: return "Pipeline started stopping."
        case .transcribing: return "Pipeline started transcription."
        case .polishing: return "Pipeline started polishing."
        case .delivering: return "Pipeline started delivery."
        case .completed: return "Pipeline completed."
        case .failed: return "Pipeline failed."
        }
    }

    private static func componentMessage(_ component: DiagnosticComponent) -> String {
        switch component {
        case .audio: return "Audio service failed."
        case .speechModel: return "Speech model service failed."
        case .transcription: return "Transcription service failed."
        case .history: return "History service failed."
        case .credential: return "Credential service failed."
        case .polishing: return "Polishing service failed."
        case .delivery: return "Delivery service failed."
        case .permissions: return "Permission service failed."
        }
    }

    private static func codeMessage(_ code: DiagnosticCode) -> String {
        switch code {
        case .permissionMicrophone: return "Code permission microphone."
        case .permissionAccessibility: return "Code permission accessibility."
        case .audioStart: return "Code audio start."
        case .audioFinalize: return "Code audio finalize."
        case .transcriptionEmpty: return "Code transcription empty."
        case .transcriptionFailed: return "Code transcription failed."
        case .historyWrite: return "Code history write."
        case .historyCorrupt: return "Code history corrupt."
        case .credentialMissing: return "Code credential missing."
        case .credentialMigrationConflict: return "Code credential migration conflict."
        case .polishTransport: return "Code polish transport."
        case .polishAuthentication: return "Code polish authentication."
        case .polishInvalidResponse: return "Code polish invalid response."
        case .deliveryTargetUnavailable: return "Code delivery target unavailable."
        case .deliveryTargetChanged: return "Code delivery target changed."
        case .deliveryPasteboardChanged: return "Code delivery pasteboard changed."
        case .deliveryDispatch: return "Code delivery dispatch."
        case .cancelled: return "Code session cancelled."
        }
    }

    private static func modelMessage(_ phase: DiagnosticModelPhase) -> String {
        switch phase {
        case .missing: return "Speech model is missing."
        case .downloading: return "Speech model is downloading."
        case .loading: return "Speech model is loading."
        case .ready: return "Speech model is ready."
        case .failed: return "Speech model failed."
        }
    }
}
