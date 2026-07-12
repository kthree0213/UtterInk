import AppKit
import SwiftUI

/// 菜单栏下拉内容（可拿到 `openSettings` 并注入 `SettingsOpener`）。
struct MenuBarRootView: View {
    @ObservedObject var appState: AppState
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"
    @AppStorage(SpeechTranscriptionSettings.languageCodeKey) private var speechTranscriptionLanguageCode =
        SpeechTranscriptionSettings.defaultLanguageCode
    @AppStorage(SpeechTranscriptionSettings.autoDetectKey) private var speechTranscriptionAutoDetect =
        SpeechTranscriptionSettings.defaultAutoDetect
    @AppStorage(WhisperModelCatalog.storageKey) private var whisperKitModelId = WhisperModelCatalog.default
    @Environment(\.openSettings) private var openSettings

    @State private var llmMenuTick = 0
    @State private var outputModesMenuTick = 0
    @State private var speechModelMenuTick = 0

    private var l10n: MenuLocalization { MenuLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private var generalSettingsL10n: SettingsLocalization { SettingsLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }

    private var menuVisibleLLMProfiles: [LLMProviderProfile] {
        _ = llmMenuTick
        return LLMProfileStorage.menuVisibleProfiles()
    }

    private var menuOutputModes: [OutputModeProfile] {
        _ = outputModesMenuTick
        return OutputModesStorage.loadModes()
    }

    /// 仅已下载到本地的变体，并始终包含当前偏好（可能尚未下载完），顺序与目录一致。
    private var menuSpeechVariants: [String] {
        _ = speechModelMenuTick
        let catalog = WhisperModelCatalog.allVariantIDs
        let pref = whisperKitModelId.isEmpty ? WhisperModelCatalog.default : whisperKitModelId
        let downloaded = Set(catalog.filter { WhisperModelCacheInspector.isVariantDownloaded($0) })
        var ordered = catalog.filter { downloaded.contains($0) }
        if !ordered.contains(pref) {
            ordered.insert(pref, at: 0)
        }
        return ordered
    }

    var body: some View {
        Group {
            Toggle(l10n.enableVoiceInput, isOn: $appState.isAppEnabled)
            Divider()

            Menu(l10n.outputMode) {
                Button(l10n.settings) {
                    openSettingsToTab(SettingsTab.outputModes)
                }
                Divider()
                ForEach(menuOutputModes) { mode in
                    let active = OutputModesStorage.activeModeId() == mode.id
                    let title = mode.displayTitle(useChinese: AppUILanguage.isChinese(uiLanguage))
                    Button((active ? "✓ " : "") + title) {
                        OutputModesStorage.setActiveModeId(mode.id)
                        outputModesMenuTick += 1
                    }
                }
            }

            Menu(l10n.llmModel) {
                Button(l10n.settings) {
                    openSettingsToTab(SettingsTab.llmProvider)
                }
                Divider()
                if menuVisibleLLMProfiles.isEmpty {
                    Button(l10n.setupOpenRouter) {
                        openSettingsToTab(SettingsTab.llmProvider)
                    }
                } else {
                    let zh = AppUILanguage.isChinese(uiLanguage)
                    let activeId = LLMProfileStorage.activeProfileId()
                    ForEach(menuVisibleLLMProfiles) { p in
                        let label = p.resolvedTitle(useChinese: zh)
                        let isCurrent = activeId == p.id
                        Button((isCurrent ? "✓ " : "") + label) {
                            LLMProfileStorage.setActiveProfileId(p.id)
                            appState.coordinator?.reloadLLMConfigurationFromDefaults()
                            llmMenuTick += 1
                        }
                    }
                }
            }

            Menu(l10n.transcriptionLanguage) {
                Button((speechTranscriptionAutoDetect ? "✓ " : "") + generalSettingsL10n.speechAutoDetectLabel) {
                    speechTranscriptionAutoDetect = true
                }
                Divider()
                ForEach(WhisperTranscriptionLanguageCatalog.menuQuickCodes, id: \.self) { code in
                    let on = !speechTranscriptionAutoDetect && speechTranscriptionLanguageCode == code
                    Button((on ? "✓ " : "") + WhisperTranscriptionLanguageCatalog.displayLabel(code: code)) {
                        speechTranscriptionAutoDetect = false
                        speechTranscriptionLanguageCode = code
                    }
                }
                Divider()
                Button(generalSettingsL10n.speechMoreLanguagesInSettings) {
                    openSettingsToTab(SettingsTab.general)
                }
            }

            Menu(l10n.speechModel) {
                Button(l10n.settings) {
                    openSettingsToTab(SettingsTab.speechModels)
                }
                Divider()
                ForEach(menuSpeechVariants, id: \.self) { id in
                    let active = whisperKitModelId == id
                    Button((active ? "✓ " : "") + id) {
                        whisperKitModelId = id
                        appState.coordinator?.scheduleWhisperModelLoad(modelId: id)
                    }
                }

                if appState.whisperModelLoadPhase != nil {
                    Divider()
                    if let p = appState.whisperModelLoadProgress {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                appState.whisperModelLoadPhase == .downloading
                                    ? l10n.downloadingModel
                                    : l10n.loadingModel
                            )
                            .font(.caption2)
                            ProgressView(value: p, total: 1)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                appState.whisperModelLoadPhase == .downloading
                                    ? l10n.downloadingModel
                                    : l10n.loadingModel
                            )
                            .font(.caption2)
                            ProgressView()
                        }
                    }
                }
            }

            Divider()

            Button(l10n.setupGuide) {
                OnboardingWindowController.shared.present(appState: appState)
            }

            Button(l10n.settings) {
                openSettingsFull()
            }
            Button(l10n.quit) { NSApplication.shared.terminate(nil) }
        }
        .onAppear {
            LLMProfileStorage.ensureDefaultLLMSelectionIfNeeded()
            SettingsOpener.openFullSettings = {
                SettingsWindowHelper.activateForSettingsPanel()
                openSettings()
                SettingsWindowHelper.bringSettingsWindowToFront()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .llmProviderProfilesDidChange)) { _ in
            llmMenuTick += 1
            appState.reloadLLMFromUserDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .outputModesDidChange)) { _ in
            outputModesMenuTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperModelDiskCacheChanged)) { _ in
            speechModelMenuTick += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            speechModelMenuTick += 1
        }
    }

    private func openSettingsFull() {
        SettingsWindowHelper.activateForSettingsPanel()
        openSettings()
        SettingsWindowHelper.bringSettingsWindowToFront()
    }

    private func openSettingsToTab(_ tab: Int) {
        SettingsTab.requestSelectTab(tab)
        openSettingsFull()
    }
}
