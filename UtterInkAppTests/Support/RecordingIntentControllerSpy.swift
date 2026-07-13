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
    var volatileResults: [DictationResult] = []
    var historyRecords: [HistoryRecord] = []
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext?
    var speechModelCatalog: [SpeechModelDescriptor] = []
    var intents: [UserIntent] = []
    var bootstrapCount = 0
    var bootstrapGate: AppBootstrapGate?

    func bootstrap() async {
        bootstrapCount += 1
        await bootstrapGate?.wait()
    }
    func send(_ intent: UserIntent) { intents.append(intent) }
    func prepareSpeechModel(_ modelID: String) {}
    func cancelSpeechModelPreparation() {}
    func deleteCachedSpeechModel(_ modelID: String) {}
}
