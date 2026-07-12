import AppKit
import AVFoundation
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("shortcutMode") private var shortcutMode = "toggle" // toggle or pushToTalk
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"
    @AppStorage(SpeechTranscriptionSettings.languageCodeKey) private var speechTranscriptionLanguageCode =
        SpeechTranscriptionSettings.defaultLanguageCode
    @AppStorage(SpeechTranscriptionSettings.autoDetectKey) private var speechTranscriptionAutoDetect =
        SpeechTranscriptionSettings.defaultAutoDetect

    @State private var axTrusted = false
    @State private var micAuthorizationStatus: AVAuthorizationStatus = .notDetermined
    @State private var profilesRevision = 0
    @State private var selectedProfileId: UUID?
    @State private var apiTestStatus = ""
    @State private var apiTestFailed = false
    @State private var isFetchingLLMModels = false
    /// 用于在切换 Tab 时强制恢复设置窗口最小尺寸（见 `SettingsWindowHelper.enforceSettingsContentMinSize`）。
    @State private var selectedSettingsTab = 0

    private var sL10n: SettingsLocalization { SettingsLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private var oL10n: OnboardingLocalization { OnboardingLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }

    private var profiles: [LLMProviderProfile] {
        _ = profilesRevision
        return LLMProfileStorage.loadProfiles()
    }

    /// 随 `profilesRevision` 刷新，供左侧「使用中」标记与「使用」按钮判断。
    private var activePolishProfileId: UUID? {
        _ = profilesRevision
        return LLMProfileStorage.activeProfileId()
    }

    var body: some View {
        TabView(selection: $selectedSettingsTab) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sL10n.interfaceLanguage)
                            .font(.subheadline.weight(.semibold))
                        Picker("", selection: $uiLanguage) {
                            Text("English").tag("en")
                            Text("中文").tag("zh")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !speechTranscriptionAutoDetect {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sL10n.speechRecognitionLanguage)
                                .font(.subheadline.weight(.semibold))
                            Picker("", selection: $speechTranscriptionLanguageCode) {
                                ForEach(WhisperTranscriptionLanguageCatalog.pickerRows, id: \.code) { row in
                                    Text(row.label).tag(row.code)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(sL10n.speechRecognitionHint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(sL10n.speechAutoDetectLabel)
                            .font(.subheadline.weight(.semibold))
                        Toggle("", isOn: $speechTranscriptionAutoDetect)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel(sL10n.speechAutoDetectLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(sL10n.speechAutoDetectCaption)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text(sL10n.generalLanguageSectionTitle)
                } footer: {
                    Color.clear.frame(height: 8)
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(oL10n.stepAXTitle)
                            .font(.headline)
                        Text(oL10n.stepAXBody)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        permissionStatusRow(
                            ok: axTrusted,
                            okText: oL10n.stepAXStatusOn,
                            badText: oL10n.stepAXStatusOff
                        )
                        Button(oL10n.stepAXOpen) {
                            TextInjector.openSystemAccessibilitySettings()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(oL10n.pathLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(TextInjector.currentExecutablePathForDiagnostics)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(oL10n.stepMicTitle)
                            .font(.headline)
                        Text(oL10n.stepMicBody)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        permissionStatusRow(
                            ok: micAuthorizationStatus == .authorized,
                            okText: oL10n.stepMicGranted,
                            badText: oL10n.stepMicDenied
                        )
                        Button(oL10n.stepMicOpen) {
                            TextInjector.openSystemMicrophonePrivacySettings()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text(sL10n.generalPermissionsSectionTitle)
                        .padding(.top, 20)
                } footer: {
                    Text(sL10n.generalPermissionsSectionFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(sL10n.generalTab, systemImage: "gearshape") }
            .tag(0)
            .onAppear { refreshPermissionsStatus() }

            SpeechModelsSettingsPane(appState: appState)
                .tabItem { Label(sL10n.speechTab, systemImage: "waveform") }
            .tag(1)

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sL10n.shortcutsTriggerModeLabel)
                            .font(.subheadline.weight(.semibold))
                        Picker("", selection: $shortcutMode) {
                            Text(sL10n.shortcutsTriggerOptionToggle).tag("toggle")
                            Text(sL10n.shortcutsTriggerOptionPushToTalk).tag("pushToTalk")
                        }
                        .labelsHidden()
                        .accessibilityLabel(sL10n.shortcutsTriggerModeLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(shortcutMode == "pushToTalk" ? sL10n.shortcutsTriggerPushToTalkExplanation : sL10n.shortcutsTriggerToggleExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(sL10n.shortcutsRecorderLabel)
                            .font(.subheadline.weight(.semibold))
                        KeyboardShortcuts.Recorder(for: .toggleRecording)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(sL10n.shortcutsCombinationHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text(sL10n.shortcutsSettingsSectionTitle)
                } footer: {
                    Color.clear.frame(height: 4)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(sL10n.shortcutsTab, systemImage: "keyboard") }
            .tag(2)

            OutputModesSettingsPane()
                .tabItem { Label(sL10n.outputModesTab, systemImage: "text.badge.plus") }
                .tag(3)

            llmProviderTabContent
                .tabItem { Label(sL10n.llmProviderTab, systemImage: "network") }
                .tag(4)
        }
        .padding(16)
        // min 与 `SettingsWindowHelper` 中 contentMin 一致，避免 Tab 切到较窄子页后窗口缩得过小。
        .frame(minWidth: 980, idealWidth: 1000, minHeight: 460, idealHeight: 500)
        .onAppear {
            SettingsWindowHelper.activateForSettingsPanel()
            SettingsWindowHelper.bringSettingsWindowToFront()
            if let tab = SettingsTab.consumePendingTabIfNeeded() {
                selectedSettingsTab = tab
            }
            syncSelectionFromStorage()
            SettingsWindowHelper.enforceSettingsContentMinSize()
            refreshPermissionsStatus()
        }
        .onChange(of: selectedSettingsTab) { _, tab in
            SettingsWindowHelper.enforceSettingsContentMinSize()
            if tab == 0 { refreshPermissionsStatus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionsStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsPreferredTabSelect)) { note in
            guard let tab = note.userInfo?["tab"] as? Int, SettingsTab.isValidTabIndex(tab) else { return }
            selectedSettingsTab = tab
            SettingsTab.discardPendingTab()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmProviderProfilesDidChange)) { _ in
            profilesRevision += 1
            let list = LLMProfileStorage.loadProfiles()
            if let s = selectedProfileId, !list.contains(where: { $0.id == s }) {
                selectedProfileId = LLMProfileStorage.activeProfileId() ?? list.first?.id
            }
        }
    }

    @ViewBuilder
    private var llmProviderTabContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(sL10n.llmProfileList)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(sL10n.llmProfileListFootnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                List(selection: $selectedProfileId) {
                    ForEach(profiles) { p in
                        HStack(alignment: .center, spacing: 6) {
                            Text(p.resolvedTitle(useChinese: sL10n.useChinese))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if activePolishProfileId == p.id {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .imageScale(.small)
                                    Text(sL10n.llmPolishDefaultBadge)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(sL10n.llmPolishDefaultBadge)
                            } else {
                                Button {
                                    setPolishDefaultProfile(id: p.id)
                                } label: {
                                    Text(sL10n.llmSetAsPolishDefault)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(nsColor: .controlAccentColor))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                .fill(Color(nsColor: .controlAccentColor).opacity(0.2))
                                        )
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .help(sL10n.llmSetAsPolishDefault)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(Optional(p.id))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 292, height: 200)
                HStack(spacing: 8) {
                    Menu {
                        Button(sL10n.llmAddOpenAI) { addProfile(template: .openAI) }
                        Button(sL10n.llmAddOpenRouter) { addProfile(template: .openRouter) }
                        Button(sL10n.llmAddGroq) { addProfile(template: .groq) }
                        Button(sL10n.llmAddTogether) { addProfile(template: .together) }
                        Button(sL10n.llmAddMiniMaxChina) { addProfile(template: .minimax) }
                        Button(sL10n.llmAddMiniMaxGlobal) { addProfile(template: .minimaxGlobal) }
                        Button(sL10n.llmAddDeepSeek) { addProfile(template: .deepSeek) }
                        Button(sL10n.llmAddMoonshot) { addProfile(template: .moonshot) }
                        Button(sL10n.llmAddSiliconFlow) { addProfile(template: .siliconFlow) }
                        Button(sL10n.llmAddAlibabaQwen) { addProfile(template: .alibabaQwen) }
                        Button(sL10n.llmAddZhipuGLM) { addProfile(template: .zhipuGLM) }
                        Button(sL10n.llmAddGoogleGemini) { addProfile(template: .googleGemini) }
                        Button(sL10n.llmAddVolcanoArk) { addProfile(template: .volcanoArk) }
                        Button(sL10n.llmAddCustom) { addProfile(template: .custom) }
                    } label: {
                        Text(sL10n.llmAddProvider)
                    }
                    Button(sL10n.llmDeleteProfile, role: .destructive) {
                        deleteSelectedProfile()
                    }
                    .disabled(selectedProfileId == nil)
                }
            }
            .frame(width: 308, alignment: .topLeading)
            .fixedSize(horizontal: true, vertical: false)

            Form {
                if profiles.isEmpty {
                    Text(sL10n.llmProfilesEmpty)
                        .foregroundStyle(.secondary)
                } else if let pid = selectedProfileId, let profile = LLMProfileStorage.profile(id: pid) {
                    TextField(sL10n.llmProfileTitle, text: titleBinding(profileId: pid))
                    if let fixedURL = profile.template.fixedOpenAIBaseURL {
                        LabeledContent(sL10n.llmApiEndpoint) {
                            Text(fixedURL)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    if profile.template == .custom {
                        TextField(sL10n.llmCustomBaseURL, text: customURLBinding(profileId: pid))
                            .textContentType(.URL)
                    }
                    let keyLabel = profile.template == .custom ? sL10n.llmApiKeyOptional : sL10n.llmApiKeyRequired
                    SecureField(keyLabel + ":", text: apiKeyBinding(profileId: pid))
                        .frame(maxWidth: 480, alignment: .leading)
                    Text(sL10n.llmProviderHint(template: profile.template))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(sL10n.llmRefreshModels) {
                        refreshLLMModels(for: pid)
                    }
                    .disabled(refreshLLMModelsDisabled(profileId: pid))
                    Text(sL10n.llmLoadModelsFootnote)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isFetchingLLMModels {
                        ProgressView()
                            .controlSize(.small)
                    }
                    let cached = LLMProfileStorage.modelsCache(for: pid) ?? []
                    if !cached.isEmpty {
                        Picker(sL10n.openRouterChatModel, selection: polishModelBinding(profileId: pid)) {
                            ForEach(cached, id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                    } else {
                        TextField(sL10n.llmManualModelField, text: polishModelBinding(profileId: pid))
                            .frame(maxWidth: 480, alignment: .leading)
                    }
                } else if !profiles.isEmpty {
                    Text(sL10n.llmSelectProfileOnLeft)
                        .foregroundStyle(.secondary)
                }
                if !apiTestStatus.isEmpty {
                    Text(apiTestStatus)
                        .font(.callout)
                        .foregroundStyle(apiTestFailed ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .layoutPriority(1)
            .frame(minWidth: 480, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func permissionStatusRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(ok ? okText : badText)
                .font(.subheadline)
        }
    }

    private func refreshPermissionsStatus() {
        axTrusted = TextInjector.isAccessibilityTrustedForCurrentProcess()
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:  micAuthorizationStatus = .authorized
            case .denied:   micAuthorizationStatus = .denied
            default:        micAuthorizationStatus = .notDetermined
            }
        } else {
            micAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private func syncSelectionFromStorage() {
        let list = LLMProfileStorage.loadProfiles()
        selectedProfileId = LLMProfileStorage.activeProfileId() ?? list.first?.id
    }

    private func setPolishDefaultProfile(id: UUID) {
        LLMProfileStorage.setActiveProfileId(id)
        appState.coordinator?.reloadLLMConfigurationFromDefaults()
    }

    private func addProfile(template: LLMProfileTemplate) {
        let id = UUID()
        let title: String = {
            if template == .custom {
                return sL10n.useChinese ? "自定义 API" : "Custom API"
            }
            return template.displayName(useChinese: sL10n.useChinese)
        }()
        let customURL: String? = template == .custom ? "http://127.0.0.1:11434/v1" : nil
        LLMProfileStorage.addProfile(
            LLMProviderProfile(id: id, title: title, template: template, customOpenAIBaseURL: customURL)
        )
        selectedProfileId = id
        profilesRevision += 1
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileId else { return }
        LLMProfileStorage.deleteProfile(id: id)
        profilesRevision += 1
        let list = LLMProfileStorage.loadProfiles()
        selectedProfileId = LLMProfileStorage.activeProfileId() ?? list.first?.id
        appState.coordinator?.reloadLLMConfigurationFromDefaults()
    }

    private func titleBinding(profileId: UUID) -> Binding<String> {
        Binding(
            get: { LLMProfileStorage.profile(id: profileId)?.title ?? "" },
            set: { newValue in
                guard var p = LLMProfileStorage.profile(id: profileId) else { return }
                p.title = newValue
                LLMProfileStorage.updateProfile(p)
            }
        )
    }

    private func customURLBinding(profileId: UUID) -> Binding<String> {
        Binding(
            get: { LLMProfileStorage.profile(id: profileId)?.customOpenAIBaseURL ?? "" },
            set: { newValue in
                guard var p = LLMProfileStorage.profile(id: profileId) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                p.customOpenAIBaseURL = trimmed.isEmpty ? nil : trimmed
                LLMProfileStorage.updateProfile(p)
            }
        )
    }

    private func apiKeyBinding(profileId: UUID) -> Binding<String> {
        Binding(
            get: { LLMProfileStorage.apiKey(for: profileId) },
            set: { LLMProfileStorage.setApiKey($0, for: profileId) }
        )
    }

    private func polishModelBinding(profileId: UUID) -> Binding<String> {
        Binding(
            get: { LLMProfileStorage.modelId(for: profileId) },
            set: { newValue in
                LLMProfileStorage.setModelId(newValue, for: profileId)
                guard profileId == LLMProfileStorage.activeProfileId() else { return }
                appState.coordinator?.reloadLLMConfigurationFromDefaults()
            }
        )
    }

    private func endpointCanRefresh(profileId: UUID) -> Bool {
        guard let p = LLMProfileStorage.profile(id: profileId),
              let ep = OpenAICompatibleEndpoint.from(profile: p, apiKey: LLMProfileStorage.apiKey(for: profileId)) else { return false }
        return ep.canUseChatAPI
    }

    private func refreshLLMModelsDisabled(profileId: UUID) -> Bool {
        isFetchingLLMModels || !endpointCanRefresh(profileId: profileId)
    }

    private func refreshLLMModels(for profileId: UUID) {
        let zh = AppUILanguage.isChinese(uiLanguage)
        apiTestFailed = false
        apiTestStatus = zh ? "正在请求模型列表…" : "Fetching model list…"
        isFetchingLLMModels = true
        Task { @MainActor in
            do {
                guard let coord = appState.coordinator else {
                    isFetchingLLMModels = false
                    apiTestFailed = true
                    apiTestStatus = zh ? "应用仍在启动，请稍后再试。" : "The app is still starting up. Try again in a moment."
                    return
                }
                let list = try await coord.refreshLLMModelList(editingProfileId: profileId)
                isFetchingLLMModels = false
                apiTestFailed = false
                let n = list.count
                apiTestStatus = zh
                    ? "已加载 \(n) 个模型，可在上方选择。"
                    : "Loaded \(n) models. Pick one above."
            } catch {
                isFetchingLLMModels = false
                apiTestFailed = true
                apiTestStatus = (zh ? "加载失败：" : "Failed: ") + error.localizedDescription
            }
        }
    }
}
