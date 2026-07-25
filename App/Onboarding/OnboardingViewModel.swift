import Foundation
import Observation
import UtterInkCore
import UtterInkServices

@MainActor
@Observable
final class OnboardingViewModel {
    private(set) var step: OnboardingStep = .privacy
    private(set) var historyEnabled = UserSettings.p0Default.historyEnabled
    private(set) var recognition = UserSettings.p0Default.recognition
    private(set) var selectedSpeechModelID = UserSettings.p0Default.speechModelID
    private(set) var microphonePermission: PermissionState = .notDetermined
    private(set) var accessibilityPermission: PermissionState = .notDetermined
    private(set) var speechModelState: SpeechModelState = .missing(
        modelID: UserSettings.p0Default.speechModelID
    )
    private(set) var pipelineState: PipelineState = .idle
    private(set) var shortcutTestPassed = false
    private(set) var isShortcutProbeArmed = false
    private(set) var isHistoryChangePending = false
    private(set) var recoverableResult: DictationResult?
    private(set) var onboardingCompleted = false
    private(set) var failureMessage: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?
    var testPasteText = ""

    let audioPrivacyText = "Audio is processed locally on this Mac and is not retained."
    let historyPrivacyText = "History stores raw and final transcript text locally on this Mac only when enabled."
    let accessibilityExplanation = "Without Accessibility, local transcription and explicit Copy still work; global shortcuts and automatic paste are limited."

    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let controller: any DictationControlling
    @ObservationIgnored private let permissions: any PermissionService
    @ObservationIgnored private let hotkeyProbe: any HotkeyProbing
    @ObservationIgnored private let onboardingSink: any OnboardingTestSink
    @ObservationIgnored private let systemSettings: any SystemSettingsNavigating

    @ObservationIgnored private var providerDisplayAuthority: String?
    @ObservationIgnored private var resultListenerTask: Task<Void, Never>?
    @ObservationIgnored private var shortcutProbeTask: Task<Void, Never>?
    @ObservationIgnored private var readinessMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var resultListenerGeneration = UUID()
    @ObservationIgnored private var shortcutProbeGeneration = UUID()
    @ObservationIgnored private var presentationGeneration = UUID()
    @ObservationIgnored private var completionInFlight = false
    @ObservationIgnored private var closeHandler: (() -> Void)?

    init(
        settings: any SettingsStore,
        controller: any DictationControlling,
        permissions: any PermissionService,
        hotkeyProbe: any HotkeyProbing,
        onboardingSink: any OnboardingTestSink,
        systemSettings: any SystemSettingsNavigating
    ) {
        self.settings = settings
        self.controller = controller
        self.permissions = permissions
        self.hotkeyProbe = hotkeyProbe
        self.onboardingSink = onboardingSink
        self.systemSettings = systemSettings
        speechModelState = controller.speechModelState
        pipelineState = controller.state
    }

    var remoteTextPrivacyText: String {
        guard let providerDisplayAuthority else {
            return "Audio never leaves this Mac. Raw mode sends no transcript text to a provider."
        }
        return "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to \(providerDisplayAuthority)."
    }

    var speechModelOptions: [SpeechModelOption] {
        controller.speechModelCatalog.map { descriptor in
            SpeechModelOption(
                descriptor: descriptor,
                title: SpeechModelOption.displayTitle(for: descriptor)
            )
        }
    }

    var modelProgress: Double? {
        guard case let .downloading(modelID, progress) = speechModelState,
              modelID == selectedSpeechModelID else { return nil }
        guard progress.isFinite else { return 0 }
        return max(0, min(progress, 1))
    }

    var selectedModelIsReady: Bool {
        speechModelState == .ready(modelID: selectedSpeechModelID)
    }

    var canStartTestDictation: Bool {
        microphonePermission != .denied
            && selectedModelIsReady
            && !isHistoryChangePending
            && [.idle, .completed, .failed].contains(pipelineState.stage)
    }

    var displayedRawText: String? {
        recoverableResult?.rawText
    }

    func setCloseHandler(_ handler: @escaping () -> Void) {
        closeHandler = handler
    }

    func prepareForPresentation(requireIncomplete: Bool = false) async {
        let generation = UUID()
        presentationGeneration = generation
        failureMessage = nil
        await load()
        guard presentationGeneration == generation else { return }
        if requireIncomplete, onboardingCompleted { return }
        await startListeningForResults()
        guard presentationGeneration == generation else { return }
        startReadinessMonitor(generation: generation)
    }

    func load() async {
        do {
            let loaded = try await settings.current()
            // The controller owns the effective runtime History state. It may
            // intentionally differ from the last persisted preference after a
            // partial storage failure, so onboarding presents the typed truth.
            historyEnabled = controller.historyControlStatus.enabled
            recognition = loaded.recognition
            selectedSpeechModelID = loaded.speechModelID
            onboardingCompleted = loaded.onboardingCompletedV2
            step = OnboardingStep(rawValue: loaded.onboardingStep) ?? .privacy
            providerDisplayAuthority = loaded.providerProfiles
                .first { $0.id == loaded.selectedProviderProfileID }
                .flatMap {
                    try? EndpointValidator.validate($0.baseURL.absoluteString).displayAuthority
                }
            await refreshReadiness()
        } catch {
            failureMessage = "Onboarding settings could not be loaded. Try reopening UtterInk."
        }
    }

    func refreshReadiness() async {
        async let microphone = permissions.microphoneState()
        async let accessibility = permissions.accessibilityState()
        microphonePermission = await microphone
        accessibilityPermission = await accessibility
        speechModelState = controller.speechModelState
        pipelineState = controller.state
    }

    func go(to destination: OnboardingStep) {
        step = destination
        failureMessage = nil
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    func goBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func setHistoryEnabled(_ enabled: Bool) async {
        historyEnabled = enabled
        failureMessage = nil
        isHistoryChangePending = true
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Applying History setting."
        )
        controller.send(.setHistoryEnabled(enabled))
        let applied = await waitForHistoryControl(expected: enabled)
        isHistoryChangePending = false
        guard applied else {
            historyEnabled = controller.historyControlStatus.enabled
            failureMessage = "History could not be changed. The test recording has not started."
            return
        }
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "History is now \(enabled ? "on" : "off")."
        )
    }

    func setRecognition(_ configuration: RecognitionConfiguration) async {
        failureMessage = nil
        do {
            let saved = try await settings.update { $0.recognition = configuration }
            recognition = saved.recognition
        } catch {
            failureMessage = "The recognition language could not be saved."
        }
    }

    func selectSpeechModel(_ modelID: String) async {
        guard controller.speechModelCatalog.contains(where: { $0.id == modelID }) else {
            failureMessage = "That speech model is unavailable."
            return
        }
        failureMessage = nil
        do {
            let saved = try await settings.update { $0.speechModelID = modelID }
            selectedSpeechModelID = saved.speechModelID
            controller.prepareSpeechModel(saved.speechModelID)
            await refreshReadiness()
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Speech model selection saved."
            )
        } catch {
            failureMessage = "The speech model choice could not be saved."
        }
    }

    func openMicrophoneSettings() {
        systemSettings.open(.microphone)
    }

    func openAccessibilitySettings() {
        systemSettings.open(.accessibility)
    }

    func armShortcutProbe() async {
        shortcutProbeTask?.cancel()
        shortcutTestPassed = false
        isShortcutProbeArmed = true
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Shortcut test armed. Press the configured shortcut now."
        )
        let generation = UUID()
        shortcutProbeGeneration = generation
        let events = await hotkeyProbe.armProbeOnly()
        shortcutProbeTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.shortcutProbeGeneration == generation {
                    self.isShortcutProbeArmed = false
                }
            }
            for await _ in events {
                guard !Task.isCancelled,
                      let self,
                      self.shortcutProbeGeneration == generation else { return }
                self.shortcutTestPassed = true
                self.accessibilityEvent = UtterInkAccessibilityEvent(
                    message: "Shortcut detected."
                )
                return
            }
        }
    }

    func startListeningForResults() async {
        guard resultListenerTask == nil else { return }
        let generation = UUID()
        resultListenerGeneration = generation
        let values = await onboardingSink.values()
        resultListenerTask = Task { @MainActor [weak self] in
            for await (sessionID, deliveredText) in values {
                guard !Task.isCancelled,
                      let self,
                      self.resultListenerGeneration == generation else { return }
                let result = self.resolveResult(
                    sessionID: sessionID,
                    deliveredText: deliveredText
                )
                await self.handleRecoverableResult(result)
            }
        }
    }

    func startTestDictation() async {
        failureMessage = nil
        await refreshReadiness()
        guard await ensureHistoryChoiceIsApplied() else {
            failureMessage = "History is not ready. The test recording has not started."
            return
        }
        guard canStartTestDictation else {
            failureMessage = readinessFailureMessage
            return
        }
        await startListeningForResults()
        controller.send(.start(.onboardingTest))
        pipelineState = controller.state
    }

    func stopTestDictation() {
        guard pipelineState.stage == .recording else { return }
        controller.send(.stop)
        pipelineState = controller.state
    }

    func cancelTestDictation() {
        guard ![.idle, .completed, .failed].contains(pipelineState.stage) else { return }
        controller.send(.cancel)
        pipelineState = controller.state
    }

    func handleRecoverableResult(_ result: DictationResult?) async {
        guard let result,
              !result.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        recoverableResult = result
        guard !onboardingCompleted, !completionInFlight else { return }
        completionInFlight = true
        defer { completionInFlight = false }
        do {
            let saved = try await settings.update {
                $0.onboardingCompletedV2 = true
                $0.onboardingStep = OnboardingStep.testDictation.rawValue
            }
            onboardingCompleted = saved.onboardingCompletedV2
            step = .testDictation
            failureMessage = nil
        } catch {
            failureMessage = "Your result is available, but onboarding progress could not be saved."
        }
    }

    func copyResult() {
        guard let recoverableResult else { return }
        controller.send(.copyResult(recoverableResult.sessionID))
    }

    func close() async {
        presentationGeneration = UUID()
        resultListenerGeneration = UUID()
        shortcutProbeGeneration = UUID()
        resultListenerTask?.cancel()
        resultListenerTask = nil
        shortcutProbeTask?.cancel()
        shortcutProbeTask = nil
        readinessMonitorTask?.cancel()
        readinessMonitorTask = nil
        isShortcutProbeArmed = false

        let savedStep = step.rawValue
        do {
            _ = try await settings.update { $0.onboardingStep = savedStep }
        } catch {
            failureMessage = "Onboarding progress could not be saved."
        }
        closeHandler?()
    }

    private var readinessFailureMessage: String {
        if microphonePermission == .denied {
            return "Microphone access is required for a test dictation."
        }
        if !selectedModelIsReady {
            return "The selected speech model must finish downloading and loading first."
        }
        return "Finish the current dictation before starting another test."
    }

    private func ensureHistoryChoiceIsApplied() async -> Bool {
        let status = controller.historyControlStatus
        if case let .settled(enabled) = status, enabled == historyEnabled {
            isHistoryChangePending = false
            return true
        }
        if case .failed = status {
            return false
        }
        if case .settled = status {
            controller.send(.setHistoryEnabled(historyEnabled))
        }
        isHistoryChangePending = true
        let applied = await waitForHistoryControl(expected: historyEnabled)
        isHistoryChangePending = false
        return applied
    }

    private func waitForHistoryControl(expected: Bool) async -> Bool {
        for _ in 0..<250 {
            switch controller.historyControlStatus {
            case let .settled(enabled):
                return enabled == expected
            case .failed:
                return false
            case .applying, .clearing:
                break
            }
            guard !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func resolveResult(
        sessionID: SessionID,
        deliveredText: String
    ) -> DictationResult? {
        if let result = controller.state.result, result.sessionID == sessionID {
            return result
        }
        if let result = controller.volatileResults.first(where: { $0.sessionID == sessionID }) {
            return result
        }
        if let record = controller.historyRecords.first(where: { $0.sessionID == sessionID }) {
            return DictationResult(
                sessionID: record.sessionID,
                startedAt: record.startedAt,
                rawText: record.rawText,
                finalText: record.finalText ?? record.rawText,
                source: record.source,
                warning: record.warning,
                delivery: record.delivery,
                persistence: .persistent
            )
        }
        return DictationResult(
            sessionID: sessionID,
            rawText: deliveredText,
            finalText: deliveredText,
            source: .raw,
            warning: nil,
            delivery: .deliveredToOnboardingTest
        )
    }

    private func startReadinessMonitor(generation: UUID) {
        readinessMonitorTask?.cancel()
        readinessMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.presentationGeneration == generation else { return }
                await self.refreshReadiness()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
