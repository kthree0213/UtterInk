import UtterInkCore

public actor SafeDiagnosticsSink: DiagnosticsSink {
    private let logger: SafeLogger
    private var lastStage: PipelineStage = .idle
    private var codes: [DiagnosticCode] = []
    private var counts: [DiagnosticComponent: Int] = [:]

    public init() {
        logger = SafeLogger()
    }

    public func record(stage: PipelineStage, code: DiagnosticCode?) async {
        lastStage = stage
        await logger.stageChanged(stage)
        guard let code else { return }

        append(code)
        guard let component = Self.component(for: code) else { return }
        increment(component)
        await logger.serviceFailed(component: component, code: code)
    }

    public func recordModelState(catalogIndex: Int, phase: DiagnosticModelPhase) async {
        guard (0..<256).contains(catalogIndex) else { return }
        increment(.speechModel)
        await logger.modelStateChanged(catalogIndex: catalogIndex, phase: phase)
    }

    public func summary() -> SafeDiagnosticsSummary {
        SafeDiagnosticsSummary(
            lastStage: lastStage,
            diagnosticCodes: codes,
            eventCounts: counts.map(DiagnosticEventCount.init(component:count:))
        )
    }

    private func append(_ code: DiagnosticCode) {
        guard !codes.contains(where: { $0.rawValue == code.rawValue }) else { return }
        if codes.count == 32 { codes.removeFirst() }
        codes.append(code)
    }

    private func increment(_ component: DiagnosticComponent) {
        counts[component] = min(
            SafeDiagnosticsSummary.maximumEventCount,
            counts[component, default: 0] + 1
        )
    }

    private static func component(for code: DiagnosticCode) -> DiagnosticComponent? {
        switch code {
        case .permissionMicrophone, .permissionAccessibility:
            return .permissions
        case .audioStart, .audioFinalize:
            return .audio
        case .transcriptionEmpty, .transcriptionFailed:
            return .transcription
        case .historyWrite, .historyCorrupt:
            return .history
        case .credentialMissing, .credentialMigrationConflict:
            return .credential
        case .polishTransport, .polishAuthentication, .polishInvalidResponse:
            return .polishing
        case .deliveryTargetUnavailable, .deliveryTargetChanged,
             .deliveryPasteboardChanged, .deliveryDispatch:
            return .delivery
        case .cancelled:
            return nil
        }
    }
}
