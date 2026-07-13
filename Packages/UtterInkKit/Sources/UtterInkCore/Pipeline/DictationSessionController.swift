import Foundation
import Observation

@MainActor
@Observable
public final class DictationSessionController: DictationControlling {
    public private(set) var state: PipelineState = .idle
    public private(set) var speechModelState: SpeechModelState
    public private(set) var speechModelCacheActionStatus: SpeechModelCacheActionStatus = .idle
    public private(set) var volatileResults: [DictationResult] = []
    public private(set) var historyRecords: [HistoryRecord] = []
    public private(set) var historyControlStatus: HistoryControlStatus = .settled(
        enabled: UserSettings.p0Default.historyEnabled
    )
    public private(set) var recordingTelemetry: RecordingTelemetry?
    public private(set) var sessionPresentation: SessionPresentationContext?
    public let speechModelCatalog: [SpeechModelDescriptor]
    public private(set) var activeSpeechModelID: String?
    public private(set) var preparingSpeechModelID: String?

    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let target: any TargetSnapshotService
    @ObservationIgnored private let permissions: any PermissionService
    @ObservationIgnored private let history: any HistoryStore
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let audio: any AudioRecordingService
    @ObservationIgnored private let models: any SpeechModelService
    @ObservationIgnored private let transcription: any TranscriptionService
    @ObservationIgnored private let polishing: any PolishingService
    @ObservationIgnored private let delivery: any DeliveryService
    @ObservationIgnored private let diagnostics: any DiagnosticsSink
    @ObservationIgnored private let clock: any AppClock

    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var bootstrapInProgress = false
    @ObservationIgnored private var currentSettings: UserSettings?
    @ObservationIgnored private var currentHistoryGeneration: UInt64 = 0
    @ObservationIgnored private var runtimeHistoryEnabled = UserSettings.p0Default.historyEnabled
    @ObservationIgnored private var effectiveHistoryEnabled = UserSettings.p0Default.historyEnabled
    @ObservationIgnored private var currentSnapshot: SessionSnapshot?
    @ObservationIgnored private var currentToken: EffectToken?
    @ObservationIgnored private var currentRecording: RecordingHandle?
    @ObservationIgnored private var currentModelLease: SpeechModelLease?
    @ObservationIgnored private var nextGeneration: UInt64 = 0
    @ObservationIgnored private var startupGeneration: UInt64 = 0
    @ObservationIgnored private var startInProgress = false
    @ObservationIgnored private var cleanupInProgress = false
    @ObservationIgnored private var sessionTask: Task<Void, Never>?

    @ObservationIgnored private var preparationGeneration: UInt64 = 0
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var modelCancellationTask: Task<Void, Never>?
    @ObservationIgnored private var modelCancellationInProgress = false
    @ObservationIgnored private var modelCancellationGeneration: UInt64 = 0

    @ObservationIgnored private var nextActionGeneration: UInt64 = 0
    @ObservationIgnored private var actionGenerations: [SessionID: UInt64] = [:]
    @ObservationIgnored private var actionTasks: [SessionID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tombstones: Set<SessionID> = []
    @ObservationIgnored private var historyControlTask: Task<Void, Never>?
    @ObservationIgnored private var historyControlRevision: UInt64 = 0

    public init(
        settings: any SettingsStore,
        target: any TargetSnapshotService,
        permissions: any PermissionService,
        history: any HistoryStore,
        credentials: any CredentialStore,
        audio: any AudioRecordingService,
        models: any SpeechModelService,
        transcription: any TranscriptionService,
        polishing: any PolishingService,
        delivery: any DeliveryService,
        diagnostics: any DiagnosticsSink,
        modelCatalog: [SpeechModelDescriptor],
        clock: any AppClock
    ) {
        self.settings = settings
        self.target = target
        self.permissions = permissions
        self.history = history
        self.credentials = credentials
        self.audio = audio
        self.models = models
        self.transcription = transcription
        self.polishing = polishing
        self.delivery = delivery
        self.diagnostics = diagnostics
        self.speechModelCatalog = modelCatalog
        self.clock = clock
        speechModelState = .missing(modelID: modelCatalog.first?.id ?? "")
    }

    deinit {
        sessionTask?.cancel()
        preparationTask?.cancel()
        historyControlTask?.cancel()
        for task in actionTasks.values {
            task.cancel()
        }
    }

    public func bootstrap() async {
        guard !bootstrapInProgress else { return }
        bootstrapInProgress = true
        defer { bootstrapInProgress = false }
        let loadedSettings: UserSettings
        do {
            loadedSettings = try await settings.current()
        } catch {
            bootstrapped = false
            await diagnostics.record(stage: .idle, code: .historyWrite)
            return
        }
        let loadedHistory: [HistoryRecord]
        do {
            loadedHistory = try await history.load()
        } catch {
            bootstrapped = false
            await diagnostics.record(stage: .idle, code: .historyCorrupt)
            return
        }
        let generation = await history.generation()
        let modelState = await models.state()
        async let microphone = permissions.microphoneState()
        async let accessibility = permissions.accessibilityState()
        _ = await (microphone, accessibility)
        currentSettings = loadedSettings
        runtimeHistoryEnabled = loadedSettings.historyEnabled
        effectiveHistoryEnabled = loadedSettings.historyEnabled
        historyControlStatus = .settled(enabled: loadedSettings.historyEnabled)
        historyRecords = loadedHistory.filter { !tombstones.contains($0.sessionID) }
        currentHistoryGeneration = generation
        publishModelState(modelState, expectedModelID: loadedSettings.speechModelID)
        bootstrapped = true
    }

    public func send(_ intent: UserIntent) {
        switch intent {
        case let .start(context):
            beginSession(context)
        case .stop:
            stopSession()
        case .cancel:
            cancelSession()
        case .acknowledge:
            if currentSnapshot == nil, state.stage == .completed || state.stage == .failed {
                state = .idle
            }
        case let .copyResult(id):
            copyResult(id)
        case let .pasteAgain(id):
            pasteAgain(id)
        case let .retryPolishing(id):
            retryPolishing(id)
        case let .deleteResult(id):
            deleteResult(id)
        case let .setHistoryEnabled(enabled):
            setHistoryEnabled(enabled)
        case .clearHistory:
            clearHistory()
        }
    }

    public func prepareSpeechModel(_ modelID: String) {
        guard speechModelCatalog.contains(where: { $0.id == modelID }),
              speechModelCacheActionStatus.deletingModelID != modelID,
              currentSnapshot == nil,
              !startInProgress,
              !cleanupInProgress else { return }
        preparationGeneration &+= 1
        let generation = preparationGeneration
        preparingSpeechModelID = modelID
        speechModelState = .missing(modelID: modelID)
        preparationTask?.cancel()
        let token = EffectToken(sessionID: SessionID(), generation: generation)
        let pendingCancellation = modelCancellationTask
        preparationTask = Task { [weak self] in
            guard let self else { return }
            await pendingCancellation?.value
            guard !Task.isCancelled,
                  self.preparationGeneration == generation,
                  self.preparingSpeechModelID == modelID else { return }
            let stream = await self.models.prepare(modelID: modelID, token: token)
            for await emitted in stream {
                guard !Task.isCancelled else { return }
                guard self.preparationGeneration == generation,
                      self.preparingSpeechModelID == modelID else { return }
                self.publishModelState(emitted, expectedModelID: modelID)
                switch self.speechModelState {
                case .ready, .failed:
                    self.preparingSpeechModelID = nil
                    self.preparationTask = nil
                    return
                case .missing, .downloading, .loading:
                    break
                }
            }
            guard self.preparationGeneration == generation else { return }
            self.preparingSpeechModelID = nil
            self.preparationTask = nil
        }
    }

    public func cancelSpeechModelPreparation() {
        guard preparingSpeechModelID != nil || preparationTask != nil else { return }
        let cancelledModelID = preparingSpeechModelID ?? speechModelState.modelID
        preparationGeneration &+= 1
        preparingSpeechModelID = nil
        preparationTask?.cancel()
        preparationTask = nil
        speechModelState = .failed(
            modelID: cancelledModelID,
            code: .cancelled,
            retryable: true
        )
        modelCancellationInProgress = true
        modelCancellationGeneration &+= 1
        let cancellationGeneration = modelCancellationGeneration
        modelCancellationTask = Task { [weak self, models] in
            await models.cancelPreparation()
            guard let self,
                  self.modelCancellationGeneration == cancellationGeneration else { return }
            self.modelCancellationInProgress = false
            self.modelCancellationTask = nil
        }
    }

    public func deleteCachedSpeechModel(_ modelID: String) {
        guard speechModelCatalog.contains(where: { $0.id == modelID }),
              !speechModelCacheActionStatus.isDeleting,
              preparingSpeechModelID != modelID,
              currentSnapshot?.speechModelID != modelID,
              activeSpeechModelID != modelID else {
            return
        }
        speechModelCacheActionStatus = .deleting(modelID: modelID)
        let pendingCancellation = modelCancellationTask
        Task { [weak self] in
            guard let self else { return }
            do {
                await pendingCancellation?.value
                let latestSettings = try await self.settings.current()
                self.currentSettings = latestSettings
                guard latestSettings.speechModelID != modelID,
                      self.currentSnapshot?.speechModelID != modelID,
                      self.preparingSpeechModelID != modelID,
                      self.activeSpeechModelID != modelID else {
                    self.speechModelCacheActionStatus = .idle
                    return
                }
                try await self.models.deleteCachedModel(modelID: modelID)
                self.speechModelCacheActionStatus = .deleted(modelID: modelID)
            } catch {
                self.speechModelCacheActionStatus = .deleteFailed(modelID: modelID)
            }
        }
    }

    private func beginSession(_ context: StartContext) {
        guard bootstrapped,
              !startInProgress,
              !cleanupInProgress,
              preparingSpeechModelID == nil,
              preparationTask == nil,
              !modelCancellationInProgress,
              currentSnapshot == nil else { return }
        switch state.stage {
        case .idle, .completed, .failed:
            break
        default:
            return
        }

        startInProgress = true
        startupGeneration &+= 1
        let startup = startupGeneration
        sessionTask = Task { [weak self] in
            await self?.startSession(context, startup: startup)
        }
    }

    private func startSession(_ context: StartContext, startup: UInt64) async {
        defer {
            if startupGeneration == startup {
                startInProgress = false
            }
        }
        do {
            var selectedSettings = try await settings.current()
            selectedSettings.historyEnabled = runtimeHistoryEnabled
            try Task.checkCancellation()
            guard startupGeneration == startup else { return }

            let observedModelState = await models.state()
            try Task.checkCancellation()
            guard startupGeneration == startup else { return }
            publishModelState(observedModelState, expectedModelID: selectedSettings.speechModelID)
            guard case let .ready(readyID) = observedModelState,
                  readyID == selectedSettings.speechModelID else {
                return
            }

            let selectedTarget: DeliveryTarget
            switch context {
            case .focusedExternal:
                selectedTarget = await target.snapshotTarget()
            case .onboardingTest:
                selectedTarget = .onboardingTest
            }
            try Task.checkCancellation()
            guard startupGeneration == startup else { return }

            // The onboarding recorder is a local, Raw-only proving ground. It
            // must not inherit a previously selected polishing mode or provider
            // when onboarding is reopened after advanced setup.
            let output: OutputMode
            let providerProfile: ProviderProfile?
            switch context {
            case .focusedExternal:
                output = selectedSettings.outputModes.first {
                    $0.id == selectedSettings.selectedOutputModeID
                } ?? .raw
                providerProfile = selectedSettings.providerProfiles.first {
                    $0.id == selectedSettings.selectedProviderProfileID
                }
            case .onboardingTest:
                output = .raw
                providerProfile = nil
            }
            let provider = providerProfile.map {
                ProviderSelection(
                    profileID: $0.id,
                    baseURL: $0.baseURL,
                    modelID: $0.modelID,
                    policy: $0.policy
                )
            }
            let credential: SessionSecret?
            if !output.skipsPolishing, let profileID = provider?.profileID {
                credential = try? await credentials.read(profileID: profileID)?.copy()
            } else {
                credential = nil
            }
            try Task.checkCancellation()
            guard startupGeneration == startup else {
                credential?.clear()
                return
            }

            let generation = await history.generation()
            try Task.checkCancellation()
            guard startupGeneration == startup else {
                credential?.clear()
                return
            }

            nextGeneration &+= 1
            let sessionID = SessionID()
            let token = EffectToken(sessionID: sessionID, generation: nextGeneration)
            let snapshot = SessionSnapshot(
                id: sessionID,
                startedAt: clock.now,
                target: selectedTarget,
                recognition: selectedSettings.recognition,
                speechModelID: selectedSettings.speechModelID,
                outputMode: output,
                provider: provider,
                historyGeneration: generation,
                historyEnabled: selectedSettings.historyEnabled,
                deliveryPreference: selectedSettings.deliveryPreference,
                credential: credential
            )
            currentSettings = selectedSettings
            currentHistoryGeneration = generation
            currentSnapshot = snapshot
            currentToken = token
            recordingTelemetry = RecordingTelemetry(startedAt: snapshot.startedAt, inputLevel: 0)
            let presentationDestination: SessionPresentationDestination
            switch selectedTarget {
            case .external:
                presentationDestination = .external
            case .copyOnly:
                presentationDestination = .copyOnlyFallback
            case .onboardingTest:
                presentationDestination = .onboardingTest
            }
            sessionPresentation = SessionPresentationContext(
                deliveryPreference: snapshot.deliveryPreference,
                destination: presentationDestination
            )
            await apply(.start(snapshot), token: token, snapshot: snapshot)
        } catch is CancellationError {
            return
        } catch {
            await diagnostics.record(stage: .idle, code: .historyWrite)
        }
    }

    private func stopSession() {
        guard let token = currentToken,
              let snapshot = currentSnapshot,
              state.stage == .recording,
              !cleanupInProgress else { return }
        sessionTask = Task { [weak self] in
            await self?.apply(.stopRequested, token: token, snapshot: snapshot)
        }
    }

    private func cancelSession() {
        if startInProgress, currentSnapshot == nil {
            startupGeneration &+= 1
            startInProgress = false
            sessionTask?.cancel()
            sessionTask = nil
            state = .idle
            return
        }
        guard let token = currentToken,
              let snapshot = currentSnapshot,
              !cleanupInProgress else { return }
        let cancelledTask = sessionTask
        cancelledTask?.cancel()
        sessionTask = Task { [weak self] in
            await cancelledTask?.value
            await self?.apply(.cancel, token: token, snapshot: snapshot)
        }
    }

    private func apply(
        _ intent: DictationIntent,
        token: EffectToken,
        snapshot: SessionSnapshot
    ) async {
        guard !Task.isCancelled || isCancellationIntent(intent), isCurrent(token) else { return }
        let reduction = DictationReducer.reduce(
            state: state,
            intent: intent,
            context: .runtime(snapshot: snapshot, startToken: token)
        )
        state = reduction.state
        if let result = reduction.state.result {
            upsertVolatile(result)
        }
        await diagnostics.record(
            stage: reduction.state.stage,
            code: reduction.state.failure?.code ?? reduction.state.result?.warning
        )
        guard !Task.isCancelled || isCancellationIntent(intent) else { return }
        for effect in reduction.effects {
            guard (!Task.isCancelled || isCancellationIntent(intent)), isCurrent(token) else { return }
            await execute(effect, snapshot: snapshot)
        }
    }

    private func execute(_ effect: DictationEffect, snapshot: SessionSnapshot) async {
        let token = effect.token
        guard isCurrent(token) else { return }
        switch effect.kind {
        case .requestMicrophone:
            let resolved = await audio.requestPermission()
            guard !Task.isCancelled, isCurrent(token) else { return }
            await apply(.microphoneResolved(resolved), token: token, snapshot: snapshot)

        case .startRecording:
            do {
                let handle = try await audio.start { [weak self] level in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(token), !self.cleanupInProgress else { return }
                        self.recordingTelemetry = RecordingTelemetry(
                            startedAt: snapshot.startedAt,
                            inputLevel: max(0, min(level, 1))
                        )
                    }
                }
                guard !Task.isCancelled, isCurrent(token) else {
                    await audio.cancel(handle)
                    return
                }
                currentRecording = handle
                await apply(.recordingStarted(handle), token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(
                    .recordingStartFailed(code(for: error, fallback: .audioStart)),
                    token: token,
                    snapshot: snapshot
                )
            }

        case .stopRecording:
            guard let handle = currentRecording else {
                await apply(.audioFinalizationFailed(.audioFinalize), token: token, snapshot: snapshot)
                return
            }
            do {
                let url = try await audio.stop(handle)
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.audioFinalized(url), token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(
                    .audioFinalizationFailed(code(for: error, fallback: .audioFinalize)),
                    token: token,
                    snapshot: snapshot
                )
            }

        case .transcribe:
            guard case let .audio(url) = effect.payload else {
                await apply(.transcriptionFailed(.transcriptionFailed), token: token, snapshot: snapshot)
                return
            }
            do {
                let lease = try await models.acquireReadyModel(
                    modelID: snapshot.speechModelID,
                    token: token
                )
                guard !Task.isCancelled, isCurrent(token) else {
                    await models.release(lease)
                    return
                }
                currentModelLease = lease
                let raw = try await transcription.transcribe(
                    audioURL: url,
                    model: lease,
                    configuration: snapshot.recognition,
                    token: token
                )
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.transcriptionSucceeded(raw), token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(
                    .transcriptionFailed(code(for: error, fallback: .transcriptionFailed)),
                    token: token,
                    snapshot: snapshot
                )
            }

        case .persistRaw:
            guard let result = state.result else { return }
            let record = HistoryRecord(
                sessionID: result.sessionID,
                startedAt: result.startedAt,
                rawText: result.rawText,
                finalText: nil,
                source: .raw,
                warning: nil,
                delivery: nil,
                outcome: .rawSaved
            )
            do {
                try await history.appendRaw(record, expectedGeneration: snapshot.historyGeneration)
                guard !Task.isCancelled, isCurrent(token) else { return }
                await refreshHistory()
                await apply(.rawPersisted, token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.rawPersistenceFailed(.historyWrite), token: token, snapshot: snapshot)
            }

        case .polish:
            guard case let .text(raw) = effect.payload else {
                await apply(.polishFailed(.polishInvalidResponse), token: token, snapshot: snapshot)
                return
            }
            do {
                let final = try await polishing.polish(rawText: raw, snapshot: snapshot, token: token)
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.polishSucceeded(final), token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(
                    .polishFailed(code(for: error, fallback: .polishInvalidResponse)),
                    token: token,
                    snapshot: snapshot
                )
            }

        case .persistFinal:
            guard let result = state.result else { return }
            do {
                try await history.updateResult(
                    sessionID: result.sessionID,
                    finalText: result.finalText,
                    source: result.source,
                    warning: result.warning,
                    delivery: result.delivery,
                    outcome: .finalized,
                    expectedGeneration: snapshot.historyGeneration
                )
                guard !Task.isCancelled, isCurrent(token) else { return }
                await refreshHistory()
                await apply(.finalPersisted, token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.finalPersistenceFailed(.historyWrite), token: token, snapshot: snapshot)
            }

        case .deliver:
            guard case let .text(text) = effect.payload else { return }
            let outcome = await delivery.deliver(
                text: text,
                to: snapshot.target,
                preference: snapshot.deliveryPreference,
                token: token
            )
            guard !Task.isCancelled, isCurrent(token) else { return }
            await apply(.deliveryFinished(outcome), token: token, snapshot: snapshot)

        case .persistDelivery:
            guard let result = state.result else { return }
            do {
                try await history.updateResult(
                    sessionID: result.sessionID,
                    finalText: result.finalText,
                    source: result.source,
                    warning: result.warning,
                    delivery: result.delivery,
                    outcome: result.delivery.map(historyOutcome(for:)) ?? .finalized,
                    expectedGeneration: snapshot.historyGeneration
                )
                guard !Task.isCancelled, isCurrent(token) else { return }
                await refreshHistory()
                await apply(.deliveryPersisted, token: token, snapshot: snapshot)
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return }
                await apply(.deliveryPersistenceFailed(.historyWrite), token: token, snapshot: snapshot)
            }

        case .cleanup:
            await finishCleanup(token: token, snapshot: snapshot)
        }
    }

    private func finishCleanup(token: EffectToken, snapshot: SessionSnapshot) async {
        guard isCurrent(token), !cleanupInProgress else { return }
        cleanupInProgress = true
        if snapshot.historyEnabled,
           let result = state.result,
           result.warning == .cancelled {
            do {
                try await history.updateResult(
                    sessionID: result.sessionID,
                    finalText: result.finalText,
                    source: result.source,
                    warning: .cancelled,
                    delivery: result.delivery,
                    outcome: .cancelled,
                    expectedGeneration: snapshot.historyGeneration
                )
                let persistent = rebuild(result, persistence: .persistent)
                upsertVolatile(persistent)
                if state.result?.sessionID == result.sessionID {
                    state.result = persistent
                }
            } catch {
                // The raw append may not have committed; the recoverable overlay stays volatile.
            }
            await refreshHistory()
        }
        let handle = currentRecording
        let lease = currentModelLease
        currentRecording = nil
        currentModelLease = nil
        snapshot.credential?.clear()
        if let lease {
            await models.release(lease)
        }
        if let handle {
            await audio.cancel(handle)
        }
        guard currentToken == token else {
            cleanupInProgress = false
            return
        }
        recordingTelemetry = nil
        sessionPresentation = nil
        currentSnapshot = nil
        currentToken = nil
        sessionTask = nil
        cleanupInProgress = false
    }

    private func copyResult(_ id: SessionID) {
        guard let result = resolvedResult(id) else {
            publishMissingActionFailure()
            return
        }
        startAction(id: id) { controller, generation, token in
            let outcome = await controller.delivery.copyExplicitly(
                text: result.finalText,
                token: token
            )
            guard controller.isActionCurrent(id, generation: generation) else { return }
            await controller.persistActionOutcome(
                result: result,
                outcome: outcome,
                actionGeneration: generation
            )
        }
    }

    private func pasteAgain(_ id: SessionID) {
        guard let result = resolvedResult(id) else {
            publishMissingActionFailure()
            return
        }
        startAction(id: id) { controller, generation, token in
            let freshTarget = await controller.target.snapshotTarget()
            guard !Task.isCancelled,
                  controller.isActionCurrent(id, generation: generation) else { return }
            let outcome = await controller.delivery.deliver(
                text: result.finalText,
                to: freshTarget,
                preference: .automaticPaste,
                token: token
            )
            guard controller.isActionCurrent(id, generation: generation) else { return }
            await controller.persistActionOutcome(
                result: result,
                outcome: outcome,
                actionGeneration: generation
            )
        }
    }

    private func retryPolishing(_ id: SessionID) {
        guard let result = resolvedResult(id) else {
            publishMissingActionFailure()
            return
        }
        startAction(id: id) { controller, generation, token in
            do {
                let settings = try await controller.settings.current()
                let output = settings.outputModes.first { $0.id == settings.selectedOutputModeID } ?? .raw
                let profile = settings.providerProfiles.first { $0.id == settings.selectedProviderProfileID }
                let provider = profile.map {
                    ProviderSelection(
                        profileID: $0.id,
                        baseURL: $0.baseURL,
                        modelID: $0.modelID,
                        policy: $0.policy
                    )
                }
                let credential: SessionSecret? = if let profileID = provider?.profileID {
                    try await controller.credentials.read(profileID: profileID)?.copy()
                } else {
                    nil
                }
                defer { credential?.clear() }
                guard !Task.isCancelled,
                      controller.isActionCurrent(id, generation: generation) else { return }
                let snapshot = SessionSnapshot(
                    id: result.sessionID,
                    startedAt: result.startedAt,
                    target: .copyOnly,
                    recognition: settings.recognition,
                    speechModelID: settings.speechModelID,
                    outputMode: output,
                    provider: provider,
                    historyGeneration: controller.currentHistoryGeneration,
                    historyEnabled: settings.historyEnabled,
                    deliveryPreference: .copyOnly,
                    credential: credential
                )
                let polished = try await controller.polishing.polish(
                    rawText: result.rawText,
                    snapshot: snapshot,
                    token: token
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !polished.isEmpty,
                      !Task.isCancelled,
                      controller.isActionCurrent(id, generation: generation) else { return }
                let updated = controller.rebuild(
                    result,
                    finalText: polished,
                    source: .polished
                )
                await controller.persistRetriedResult(
                    updated,
                    actionGeneration: generation
                )
            } catch {
                guard controller.isActionCurrent(id, generation: generation) else { return }
                controller.publishRecoverableActionFailure(
                    controller.code(for: error, fallback: .polishInvalidResponse),
                    result: result
                )
            }
        }
    }

    private func deleteResult(_ id: SessionID) {
        tombstones.insert(id)
        invalidateAction(id)
        volatileResults.removeAll { $0.sessionID == id }
        historyRecords.removeAll { $0.sessionID == id }
        if state.result?.sessionID == id {
            state.result = nil
        }
        if currentSnapshot?.id == id {
            cancelSession()
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.history.delete(sessionID: id)
                await self.refreshHistory()
            } catch {
                await self.diagnostics.record(stage: self.state.stage, code: .historyWrite)
            }
        }
    }

    private func setHistoryEnabled(_ enabled: Bool) {
        if !enabled {
            invalidateAllActions()
            runtimeHistoryEnabled = false
        }
        historyControlRevision &+= 1
        let revision = historyControlRevision
        historyControlStatus = .applying(enabled: enabled)
        let predecessor = historyControlTask
        historyControlTask = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            let generation: UInt64
            do {
                generation = try await self.history.setEnabled(enabled)
            } catch {
                if self.historyControlRevision == revision {
                    self.runtimeHistoryEnabled = self.effectiveHistoryEnabled
                    self.historyControlStatus = .failed(
                        enabled: self.effectiveHistoryEnabled,
                        failure: .applyFailed
                    )
                }
                await self.diagnostics.record(stage: self.state.stage, code: .historyWrite)
                return
            }
            self.effectiveHistoryEnabled = enabled
            if self.historyControlRevision == revision {
                self.runtimeHistoryEnabled = enabled
            }
            self.currentHistoryGeneration = generation
            self.currentSettings?.historyEnabled = enabled
            let value: UserSettings
            do {
                value = try await self.settings.update {
                    $0.historyEnabled = enabled
                }
            } catch {
                if self.historyControlRevision == revision {
                    self.historyControlStatus = .failed(
                        enabled: enabled,
                        failure: .preferenceSaveFailed
                    )
                }
                await self.diagnostics.record(stage: self.state.stage, code: .historyWrite)
                return
            }
            self.currentSettings = value
            guard self.historyControlRevision == revision else { return }
            if enabled {
                await self.refreshHistory(expectedHistoryControlRevision: revision)
            } else {
                self.volatileResults = self.volatileResults.map {
                    self.rebuild($0, persistence: .volatile)
                }
            }
            guard self.historyControlRevision == revision else { return }
            self.historyControlStatus = .settled(enabled: enabled)
        }
    }

    private func clearHistory() {
        cancelSession()
        invalidateAllActions()
        historyControlRevision &+= 1
        let revision = historyControlRevision
        historyControlStatus = .clearing(enabled: effectiveHistoryEnabled)
        tombstones.formUnion(volatileResults.map(\.sessionID))
        tombstones.formUnion(historyRecords.map(\.sessionID))
        volatileResults = []
        historyRecords = []
        let predecessor = historyControlTask
        historyControlTask = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            let enabled = self.effectiveHistoryEnabled
            do {
                let generation = try await self.history.clear()
                guard self.historyControlRevision == revision else { return }
                self.currentHistoryGeneration = generation
                self.historyRecords = []
                self.volatileResults = []
                self.historyControlStatus = .settled(enabled: enabled)
            } catch {
                if self.historyControlRevision == revision {
                    self.historyControlStatus = .failed(
                        enabled: enabled,
                        failure: .clearFailed
                    )
                }
                await self.diagnostics.record(stage: self.state.stage, code: .historyWrite)
            }
        }
    }

    private func startAction(
        id: SessionID,
        operation: @escaping @MainActor (
            DictationSessionController,
            UInt64,
            EffectToken
        ) async -> Void
    ) {
        invalidateAction(id)
        nextActionGeneration &+= 1
        let generation = nextActionGeneration
        actionGenerations[id] = generation
        let token = EffectToken(sessionID: id, generation: generation)
        actionTasks[id] = Task { [weak self] in
            guard let self else { return }
            await operation(self, generation, token)
            if self.actionGenerations[id] == generation {
                self.actionTasks[id] = nil
            }
        }
    }

    private func persistActionOutcome(
        result: DictationResult,
        outcome: DeliveryOutcome,
        actionGeneration: UInt64
    ) async {
        guard isActionCurrent(result.sessionID, generation: actionGeneration) else { return }
        guard let latest = resolvedResult(result.sessionID) else { return }
        let updated = rebuild(latest, delivery: outcome)
        upsertVolatile(updated)
        if state.result?.sessionID == result.sessionID {
            state.result = updated
        }
        guard latest.persistence == .persistent,
              currentSettings?.historyEnabled == true else { return }
        let generation = currentHistoryGeneration
        do {
            try await history.updateResult(
                sessionID: result.sessionID,
                finalText: updated.finalText,
                source: updated.source,
                warning: updated.warning,
                delivery: outcome,
                outcome: historyOutcome(for: outcome),
                expectedGeneration: generation
            )
            guard isActionCurrent(result.sessionID, generation: actionGeneration),
                  currentHistoryGeneration == generation else { return }
            await refreshHistory()
        } catch {
            guard isActionCurrent(result.sessionID, generation: actionGeneration) else { return }
            publishRecoverableActionFailure(.historyWrite, result: updated)
        }
    }

    private func persistRetriedResult(
        _ result: DictationResult,
        actionGeneration: UInt64
    ) async {
        guard isActionCurrent(result.sessionID, generation: actionGeneration) else { return }
        if result.persistence == .persistent, currentSettings?.historyEnabled == true {
            let generation = currentHistoryGeneration
            do {
                try await history.updateResult(
                    sessionID: result.sessionID,
                    finalText: result.finalText,
                    source: result.source,
                    warning: result.warning,
                    delivery: result.delivery,
                    outcome: .finalized,
                    expectedGeneration: generation
                )
                guard isActionCurrent(result.sessionID, generation: actionGeneration),
                      currentHistoryGeneration == generation else { return }
                await refreshHistory()
            } catch {
                guard isActionCurrent(result.sessionID, generation: actionGeneration) else { return }
                publishRecoverableActionFailure(.historyWrite, result: result)
                return
            }
        }
        guard isActionCurrent(result.sessionID, generation: actionGeneration) else { return }
        let published: DictationResult
        if result.persistence == .persistent, currentSettings?.historyEnabled != true {
            published = rebuild(result, persistence: .volatile)
        } else {
            published = result
        }
        upsertVolatile(published)
        if state.result?.sessionID == result.sessionID {
            state.result = published
        }
    }

    private func refreshHistory(expectedHistoryControlRevision: UInt64? = nil) async {
        do {
            let loaded = try await history.load()
            if let expectedHistoryControlRevision,
               historyControlRevision != expectedHistoryControlRevision {
                return
            }
            historyRecords = loaded.filter { !tombstones.contains($0.sessionID) }
        } catch {
            await diagnostics.record(stage: state.stage, code: .historyCorrupt)
        }
    }

    private func upsertVolatile(_ result: DictationResult) {
        guard !tombstones.contains(result.sessionID) else { return }
        volatileResults.removeAll { $0.sessionID == result.sessionID }
        volatileResults.insert(result, at: 0)
        if volatileResults.count > 20 {
            volatileResults.removeLast(volatileResults.count - 20)
        }
    }

    private func resolvedResult(_ id: SessionID) -> DictationResult? {
        guard !tombstones.contains(id) else { return nil }
        if let result = volatileResults.first(where: { $0.sessionID == id }) {
            return result
        }
        guard let record = historyRecords.first(where: { $0.sessionID == id }) else { return nil }
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

    private func invalidateAction(_ id: SessionID) {
        actionTasks[id]?.cancel()
        actionTasks[id] = nil
        actionGenerations[id] = nil
    }

    private func invalidateAllActions() {
        for task in actionTasks.values {
            task.cancel()
        }
        actionTasks = [:]
        actionGenerations = [:]
    }

    private func isActionCurrent(_ id: SessionID, generation: UInt64) -> Bool {
        !Task.isCancelled
            && !tombstones.contains(id)
            && actionGenerations[id] == generation
    }

    private func isCurrent(_ token: EffectToken) -> Bool {
        currentToken == token && currentSnapshot?.id == token.sessionID
    }

    private func isCancellationIntent(_ intent: DictationIntent) -> Bool {
        if case .cancel = intent { return true }
        return false
    }

    private func publishMissingActionFailure() {
        publishRecoverableActionFailure(.historyWrite, result: nil)
    }

    private func publishRecoverableActionFailure(
        _ code: DiagnosticCode,
        result: DictationResult?
    ) {
        guard currentSnapshot == nil else {
            Task { [diagnostics, stage = state.stage] in
                await diagnostics.record(stage: stage, code: code)
            }
            return
        }
        state = PipelineState(
            stage: .failed,
            sessionID: result?.sessionID,
            token: nil,
            result: result,
            failure: PipelineFailure(code: code, recoverableResult: result)
        )
    }

    private func publishModelState(
        _ value: SpeechModelState,
        expectedModelID: String
    ) {
        if case let .ready(modelID) = value,
           speechModelCatalog.contains(where: { $0.id == modelID }) {
            activeSpeechModelID = modelID
        }
        let sanitized = sanitizeModelState(value, expectedModelID: expectedModelID)
        speechModelState = sanitized
    }

    private func sanitizeModelState(
        _ value: SpeechModelState,
        expectedModelID: String
    ) -> SpeechModelState {
        switch value {
        case .missing:
            return .missing(modelID: expectedModelID)
        case let .downloading(modelID, progress) where modelID == expectedModelID:
            let bounded = progress.isFinite ? max(0, min(progress, 1)) : 0
            return .downloading(modelID: expectedModelID, progress: bounded)
        case let .loading(modelID) where modelID == expectedModelID:
            return .loading(modelID: expectedModelID)
        case let .ready(modelID) where modelID == expectedModelID:
            return .ready(modelID: expectedModelID)
        case let .failed(modelID, code, retryable) where modelID == expectedModelID:
            return .failed(modelID: expectedModelID, code: code, retryable: retryable)
        default:
            return .missing(modelID: expectedModelID)
        }
    }

    private func historyOutcome(for delivery: DeliveryOutcome) -> HistoryOutcome {
        if case .manualCopyRequired = delivery {
            return .finalized
        }
        return .delivered
    }

    private func code(for error: Error, fallback: DiagnosticCode) -> DiagnosticCode {
        (error as? DiagnosticCode) ?? fallback
    }

    private func rebuild(
        _ result: DictationResult,
        finalText: String? = nil,
        source: ResultSource? = nil,
        delivery: DeliveryOutcome? = nil,
        persistence: ResultPersistence? = nil
    ) -> DictationResult {
        DictationResult(
            sessionID: result.sessionID,
            startedAt: result.startedAt,
            rawText: result.rawText,
            finalText: finalText ?? result.finalText,
            source: source ?? result.source,
            warning: result.warning,
            delivery: delivery ?? result.delivery,
            persistence: persistence ?? result.persistence
        )
    }
}

private extension SpeechModelCacheActionStatus {
    var isDeleting: Bool {
        if case .deleting = self { return true }
        return false
    }

    var deletingModelID: String? {
        if case let .deleting(modelID) = self { return modelID }
        return nil
    }
}
