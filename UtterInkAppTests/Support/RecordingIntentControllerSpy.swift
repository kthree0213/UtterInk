import UtterInkCore

actor AppBootstrapGate {
    private var isOpen = false
    private var hasEntered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        for _ in 0..<2_000 {
            if hasEntered { return }
            await Task.yield()
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
    var cachedSpeechModelIDs: Set<String> = []
    var activeSpeechModelID: String?
    var preparingSpeechModelID: String?
    var intents: [UserIntent] = []
    var preparedSpeechModelIDs: [String] = []
    var cancelPreparationCount = 0
    var deletedSpeechModelIDs: [String] = []
    var rejectPreparation = false
    var bootstrapCount = 0
    var bootstrapGate: AppBootstrapGate?
    var refreshSpeechModelCacheCount = 0
    var historyChangeHandler: (@MainActor (Bool) async -> Bool)?
    private var historyControlRevision: UInt64 = 0

    func bootstrap() async {
        bootstrapCount += 1
        await bootstrapGate?.wait()
    }
    func refreshSpeechModelCache() async {
        refreshSpeechModelCacheCount += 1
    }
    func send(_ intent: UserIntent) {
        intents.append(intent)
        switch intent {
        case let .setHistoryEnabled(enabled):
            historyControlRevision &+= 1
            let revision = historyControlRevision
            historyControlStatus = .applying(enabled: enabled)
            let handler = historyChangeHandler
            Task { @MainActor [weak self] in
                let succeeded = await handler?(enabled) ?? true
                guard let self, self.historyControlRevision == revision else { return }
                self.historyControlStatus = succeeded
                    ? .settled(enabled: enabled)
                    : .failed(enabled: enabled, failure: .preferenceSaveFailed)
            }
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
        cachedSpeechModelIDs.remove(modelID)
        speechModelCacheActionStatus = .deleted(modelID: modelID)
    }
}
