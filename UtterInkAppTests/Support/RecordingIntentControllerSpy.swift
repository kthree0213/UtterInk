import UtterInkCore

actor AppBootstrapGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class RecordingIntentControllerSpy: DictationControlling {
    var state: PipelineState = .idle
    var speechModelState: SpeechModelState = .ready(modelID: "small")
    var speechModelCacheActionStatus: SpeechModelCacheActionStatus = .idle
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var historyControlStatus: HistoryControlStatus = .settled(enabled: true)
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext?
    var speechModelCatalog: [SpeechModelDescriptor] = []
    var activeSpeechModelID: String?
    var preparingSpeechModelID: String?
    var intents: [UserIntent] = []
    var preparedSpeechModelIDs: [String] = []
    var cancelPreparationCount = 0
    var deletedSpeechModelIDs: [String] = []
    var rejectPreparation = false
    var bootstrapCount = 0
    var bootstrapGate: AppBootstrapGate?

    func bootstrap() async {
        bootstrapCount += 1
        await bootstrapGate?.wait()
    }
    func send(_ intent: UserIntent) {
        intents.append(intent)
        switch intent {
        case let .setHistoryEnabled(enabled):
            historyControlStatus = .settled(enabled: enabled)
        case .clearHistory:
            historyControlStatus = .settled(enabled: historyControlStatus.enabled)
        default:
            break
        }
    }
    func prepareSpeechModel(_ modelID: String) {
        guard !rejectPreparation else { return }
        preparedSpeechModelIDs.append(modelID)
        preparingSpeechModelID = modelID
    }
    func cancelSpeechModelPreparation() {
        cancelPreparationCount += 1
        preparingSpeechModelID = nil
    }
    func deleteCachedSpeechModel(_ modelID: String) {
        deletedSpeechModelIDs.append(modelID)
        speechModelCacheActionStatus = .deleted(modelID: modelID)
    }
}
