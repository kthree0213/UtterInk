import Foundation
import WhisperKit

@MainActor
class FlowCoordinator {
    let appState: AppState
    let llmProcessor: LLMProcessor
    let textInjector: TextInjector
    let hotkeyManager: HotkeyManager
    private let microphoneRecorder = MicrophoneRecorder()
    var whisperKit: WhisperKit?
    /// 当前已成功加载的变体 id，与 `UserDefaults` 一致，用于跳过重复加载。
    private var loadedWhisperVariantId: String?
    /// 供界面判断「当前内存里用的是哪一档 Whisper」。
    var activeLoadedWhisperVariantId: String? { loadedWhisperVariantId }
    private var whisperLoadGeneration = 0
    private var whisperLoadTask: Task<Void, Never>?

    init(appState: AppState) {
        self.appState = appState
        SpeechTranscriptionSettings.migrateUserDefaultsIfNeeded()
        let ep = OpenAICompatibleEndpoint.fromActiveProfile() ?? OpenAICompatibleEndpoint.idlePlaceholderEndpoint()
        self.llmProcessor = LLMProcessor(endpoint: ep)
        self.textInjector = TextInjector()
        self.hotkeyManager = HotkeyManager()

        setupBindings()
        let initial = UserDefaults.standard.string(forKey: WhisperModelCatalog.storageKey) ?? WhisperModelCatalog.default
        scheduleWhisperModelLoad(modelId: initial)
        if let pid = LLMProfileStorage.activeProfileId() {
            appState.availableModels = LLMProfileStorage.modelsCache(for: pid) ?? []
        }
    }

    /// 重新加载当前激活档案对应的端点，并同步已缓存的模型列表到界面。
    func reloadLLMConfigurationFromDefaults() {
        guard let ep = OpenAICompatibleEndpoint.fromActiveProfile() else { return }
        llmProcessor.replaceEndpoint(ep)
        if let pid = LLMProfileStorage.activeProfileId() {
            appState.availableModels = LLMProfileStorage.modelsCache(for: pid) ?? []
        }
    }

    /// 拉取指定档案（默认当前激活）的模型列表并写入缓存。
    func refreshLLMModelList(editingProfileId: UUID? = nil) async throws -> [String] {
        let profileId = editingProfileId ?? LLMProfileStorage.activeProfileId()
        guard let pid = profileId, let profile = LLMProfileStorage.profile(id: pid) else {
            let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
            throw NSError(
                domain: "FlowType",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: zh ? "没有可用的模型供应商配置。" : "No LLM provider profile is configured."]
            )
        }
        let key = LLMProfileStorage.apiKey(for: pid)
        guard let ep = OpenAICompatibleEndpoint.from(profile: profile, apiKey: key), ep.canUseChatAPI else {
            let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
            throw NSError(
                domain: "FlowType",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: zh
                    ? "当前配置无法连接服务商（例如未填写 Key 或地址无效）。"
                    : "This setup can’t reach the provider (e.g. missing key or invalid URL)."]
            )
        }
        let worker = LLMProcessor(endpoint: ep)
        let models = try await worker.fetchChatModelIdentifiers()
        LLMProfileStorage.setModelsCache(models, for: pid)
        if pid == LLMProfileStorage.activeProfileId() {
            llmProcessor.replaceEndpoint(ep)
            appState.availableModels = models
        }
        let def = profile.template.defaultModelId
        let fallback: String = {
            if models.contains(def) { return def }
            return models.first ?? def
        }()
        let current = LLMProfileStorage.modelId(for: pid).trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || !models.contains(current) {
            LLMProfileStorage.setModelId(fallback, for: pid)
        }
        return models
    }

    /// 切换或首次加载 Whisper 变体：下载阶段带 `Progress` 回调，再 `loadModels`。
    func scheduleWhisperModelLoad(modelId: String) {
        if loadedWhisperVariantId == modelId, whisperKit != nil { return }

        whisperLoadTask?.cancel()
        whisperLoadGeneration += 1
        let generation = whisperLoadGeneration
        loadedWhisperVariantId = nil
        whisperKit = nil
        appState.whisperTargetLoadVariantId = modelId

        whisperLoadTask = Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run {
                guard self.whisperLoadGeneration == generation else { return }
                self.appState.whisperModelLoadProgress = 0
                self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                self.appState.whisperModelLoadPhase = .downloading
            }

            do {
                let downloadBase = try WhisperModelCacheInspector.ensureDownloadBaseDirectory()

                let existingPath: String? = await MainActor.run {
                    WhisperModelCacheInspector.findDownloadedFolder(for: modelId)?.path
                }

                let modelFolder: URL
                if let path = existingPath {
                    modelFolder = URL(fileURLWithPath: path)
                    await MainActor.run {
                        guard self.whisperLoadGeneration == generation else { return }
                        self.appState.whisperModelLoadProgress = 1
                        self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                        self.appState.whisperModelLoadPhase = .loading
                    }
                } else {
                    modelFolder = try await WhisperKit.download(
                        variant: modelId,
                        downloadBase: downloadBase,
                        progressCallback: { progress in
                            let f = progress.fractionCompleted
                            let clamped = f.isFinite ? max(0, min(1, f)) : 0
                            let tp = progress.flowTypeEstimatedThroughputBytesPerSecond
                            Task { @MainActor in
                                guard self.whisperLoadGeneration == generation else { return }
                                self.appState.whisperModelLoadProgress = clamped
                                self.appState.whisperModelLoadThroughputBytesPerSecond = tp
                            }
                        }
                    )

                    await MainActor.run {
                        guard self.whisperLoadGeneration == generation else { return }
                        self.appState.whisperModelLoadProgress = 1
                        self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                        self.appState.whisperModelLoadPhase = .loading
                    }
                }

                // 必须提供 downloadBase / tokenizerFolder，否则 WhisperKit 内 HubApi(downloadBase: nil) 会落到「文稿/huggingface」并触发系统文稿权限。
                let config = WhisperKitConfig(
                    downloadBase: downloadBase,
                    modelFolder: modelFolder.path,
                    tokenizerFolder: modelFolder,
                    verbose: false,
                    load: true,
                    download: false
                )
                let kit = try await WhisperKit(config)

                await MainActor.run {
                    guard self.whisperLoadGeneration == generation else { return }
                    self.whisperKit = kit
                    self.loadedWhisperVariantId = modelId
                    UserDefaults.standard.set(modelId, forKey: WhisperModelCatalog.storageKey)
                    self.appState.whisperModelLoadProgress = nil
                    self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                    self.appState.whisperModelLoadPhase = nil
                    self.appState.whisperTargetLoadVariantId = nil
                    self.whisperLoadTask = nil
                    NotificationCenter.default.post(name: .whisperModelDiskCacheChanged, object: nil)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.whisperLoadGeneration == generation else { return }
                    self.appState.whisperModelLoadProgress = nil
                    self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                    self.appState.whisperModelLoadPhase = nil
                    self.appState.whisperTargetLoadVariantId = nil
                    self.whisperLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard self.whisperLoadGeneration == generation else { return }
                    self.appState.whisperModelLoadProgress = nil
                    self.appState.whisperModelLoadThroughputBytesPerSecond = nil
                    self.appState.whisperModelLoadPhase = nil
                    self.appState.whisperTargetLoadVariantId = nil
                    self.whisperLoadTask = nil
                    let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                    self.appState.setUserNotice(
                        zh
                            ? "语音模型加载失败：\(error.localizedDescription)"
                            : "Speech model error: \(error.localizedDescription)",
                        action: .none
                    )
                }
            }
        }
    }

    /// 取消当前正在进行的 Whisper 下载或加载（若正在向 Core ML 载入，也会中止后续步骤）。
    func cancelWhisperModelLoad() {
        whisperLoadTask?.cancel()
        whisperLoadTask = nil
        whisperLoadGeneration += 1
        appState.whisperModelLoadProgress = nil
        appState.whisperModelLoadThroughputBytesPerSecond = nil
        appState.whisperModelLoadPhase = nil
        appState.whisperTargetLoadVariantId = nil
    }

    /// 从磁盘删除某变体缓存；若该变体正在使用或正在下载，会先卸载/取消。
    func removeWhisperVariantFromDisk(_ variant: String) throws {
        if appState.whisperTargetLoadVariantId == variant {
            cancelWhisperModelLoad()
        }
        if loadedWhisperVariantId == variant {
            whisperKit = nil
            loadedWhisperVariantId = nil
        }
        try WhisperModelCacheInspector.deleteCachedVariant(variant)
    }

    /// 仅下载到本机 Hugging Face 缓存（`Application Support/FlowType/huggingface`），不切换当前使用的模型。
    func prefetchWhisperVariant(
        _ variant: String,
        onProgress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws {
        let downloadBase = try WhisperModelCacheInspector.ensureDownloadBaseDirectory()
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            progressCallback: { progress in
                let f = progress.fractionCompleted
                let clamped = f.isFinite ? max(0, min(1, f)) : 0
                let tp = progress.flowTypeEstimatedThroughputBytesPerSecond
                Task { @MainActor in
                    onProgress(clamped, tp)
                }
            }
        )
    }

    func startRecording() {
        guard appState.isAppEnabled else { return }
        appState.clearUserNotice()
        Task { @MainActor in
            let granted = await MicrophoneRecorder.requestMicrophonePermission()
            guard granted else {
                let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                self.appState.setUserNotice(
                    zh
                        ? "需要麦克风权限才能录音。请在系统设置 → 隐私与安全性 → 麦克风中开启 FlowType。"
                        : "Microphone access is required. Enable FlowType under System Settings → Privacy & Security → Microphone.",
                    action: .microphone
                )
                return
            }
            do {
                self.appState.microphoneInputLevel = 0
                try self.microphoneRecorder.startRecording { [weak self] level in
                    DispatchQueue.main.async {
                        guard let self, self.appState.isRecording else { return }
                        self.appState.microphoneInputLevel = CGFloat(min(1, max(0, level)))
                    }
                }
                self.appState.recordingStartedAt = Date()
                self.appState.isRecording = true
            } catch {
                let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                self.appState.setUserNotice(
                    zh
                        ? "无法启动录音：\(error.localizedDescription)"
                        : "Could not start recording: \(error.localizedDescription)",
                    action: .none
                )
            }
        }
    }

    func stopRecording() {
        guard appState.isRecording else { return }
        appState.microphoneInputLevel = 0
        appState.recordingStartedAt = nil
        appState.isRecording = false
        guard let fileURL = microphoneRecorder.stopRecording() else {
            appState.isProcessing = false
            return
        }
        appState.isProcessing = true
        processRecordedAudio(fileURL: fileURL)
    }

    private func setupBindings() {
        hotkeyManager.onRecordingStart = { [weak self] in
            self?.startRecording()
        }

        hotkeyManager.onRecordingStop = { [weak self] in
            self?.stopRecording()
        }
    }

    private func endProcessingWithAccessibilityNoticeIfNeeded() -> Bool {
        guard textInjector.ensureTrustedForInjection() else {
            let path = TextInjector.currentExecutablePathForDiagnostics
            let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
            let bodyZh = [
                "需要「辅助功能」权限才能向其它应用粘贴。",
                "",
                "请打开「系统设置 → 隐私与安全性 → 辅助功能」，在列表中找到 FlowType 并打开。若出现多条同名，一般选择「应用程序」文件夹里的那一个；若没有，可用「+」从应用程序里选取 FlowType。",
                "",
                "应用位置（供核对）：",
                path,
                "",
                "回到本应用会自动再检测；若仍不行请完全退出后重新打开。"
            ].joined(separator: "\n")
            let bodyEn = [
                "Accessibility permission is required to paste into other apps.",
                "",
                "Open System Settings → Privacy & Security → Accessibility and turn on FlowType. If you see multiple entries, choose the one inside your Applications folder; use “+” to add the app if it’s missing.",
                "",
                "App location (for verification):",
                path,
                "",
                "Return to this app to re-check; if it still fails, quit completely and launch again."
            ].joined(separator: "\n")
            appState.setUserNotice(zh ? bodyZh : bodyEn, action: .accessibility)
            appState.isProcessing = false
            return false
        }
        return true
    }

    private func waitForWhisperKit(maxWaitSeconds: TimeInterval = 120) async -> WhisperKit? {
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            let kit = await MainActor.run { self.whisperKit }
            if kit != nil { return kit }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await MainActor.run { self.whisperKit }
    }

    private static func decodingOptionsFromUserDefaults() -> DecodingOptions {
        SpeechTranscriptionSettings.migrateUserDefaultsIfNeeded()
        let d = UserDefaults.standard
        if d.bool(forKey: SpeechTranscriptionSettings.autoDetectKey) {
            return DecodingOptions(verbose: false, language: nil, detectLanguage: true)
        }
        let code =
            d.string(forKey: SpeechTranscriptionSettings.languageCodeKey)
            ?? SpeechTranscriptionSettings.defaultLanguageCode
        return DecodingOptions(verbose: false, language: code, detectLanguage: false)
    }

    private func processRecordedAudio(fileURL: URL) {
        Task {
            defer { try? FileManager.default.removeItem(at: fileURL) }

            let kit = await waitForWhisperKit()
            let transcribed: String
            if let kit {
                do {
                    let options = Self.decodingOptionsFromUserDefaults()
                    let results = try await kit.transcribe(audioPath: fileURL.path, decodeOptions: options)
                    transcribed = results.map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    await MainActor.run {
                        let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                        self.appState.setUserNotice(
                            zh
                                ? "语音转写失败：\(error.localizedDescription)"
                                : "Transcription failed: \(error.localizedDescription)",
                            action: .none
                        )
                        self.appState.isProcessing = false
                    }
                    return
                }
            } else {
                await MainActor.run {
                    let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                    self.appState.setUserNotice(
                        zh
                            ? "语音模型仍在加载或下载中，请稍后再试。"
                            : "The speech model is still downloading or loading. Please try again shortly.",
                        action: .none
                    )
                    self.appState.isProcessing = false
                }
                return
            }

            guard !transcribed.isEmpty else {
                await MainActor.run {
                    let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                    self.appState.setUserNotice(
                        zh
                            ? "未识别到有效语音（可能过短或几乎无声）。"
                            : "No speech detected (too short or silent).",
                        action: .none
                    )
                    self.appState.isProcessing = false
                }
                return
            }

            await MainActor.run {
                self.finishTranscribedPipeline(transcribed)
            }
        }
    }

    private func finishTranscribedPipeline(_ transcribedText: String) {
        reloadLLMConfigurationFromDefaults()
        let modeProfile = OutputModesStorage.activeMode()
        let skipLLM = modeProfile?.skipsLLM == true || !llmProcessor.canUseChatAPI

        if skipLLM {
            guard endProcessingWithAccessibilityNoticeIfNeeded() else { return }
            textInjector.inject(text: transcribedText)
            appState.clearUserNotice()
            appState.isProcessing = false
            return
        }

        Task {
            do {
                guard let pid = LLMProfileStorage.activeProfileId() else {
                    let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                    throw NSError(
                        domain: "FlowType",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: zh ? "没有选中的模型供应商。" : "No LLM provider profile is selected."]
                    )
                }
                let profile = LLMProfileStorage.profile(id: pid)
                let def = profile?.template.defaultModelId ?? OpenRouterConfig.defaultChatModelId
                let saved = LLMProfileStorage.modelId(for: pid).trimmingCharacters(in: .whitespacesAndNewlines)
                let model = saved.isEmpty ? def : saved
                let systemPrompt = modeProfile?.systemPrompt ?? ""
                let result = try await llmProcessor.process(text: transcribedText, model: model, systemPrompt: systemPrompt)
                await MainActor.run {
                    guard self.endProcessingWithAccessibilityNoticeIfNeeded() else { return }
                    self.textInjector.inject(text: result)
                    self.appState.clearUserNotice()
                    self.appState.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    guard self.endProcessingWithAccessibilityNoticeIfNeeded() else { return }
                    self.textInjector.inject(text: transcribedText)
                    let zh = AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
                    self.appState.setUserNotice(
                        zh
                            ? "AI 处理未成功（已粘贴原文）：\(error.localizedDescription)"
                            : "AI step failed (raw text pasted): \(error.localizedDescription)",
                        action: .none
                    )
                    self.appState.isProcessing = false
                }
            }
        }
    }

    func start() {
        hotkeyManager.startListening()
    }
}
