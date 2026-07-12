import AVFoundation
import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @AppStorage(AppUILanguage.storageKey) private var uiLanguage = "en"
    @AppStorage(WhisperModelCatalog.storageKey) private var whisperKitModelId = WhisperModelCatalog.default
    @AppStorage(SpeechTranscriptionSettings.languageCodeKey) private var speechTranscriptionLanguageCode =
        SpeechTranscriptionSettings.defaultLanguageCode
    @AppStorage(SpeechTranscriptionSettings.autoDetectKey) private var speechTranscriptionAutoDetect =
        SpeechTranscriptionSettings.defaultAutoDetect
    @State private var step = 0
    @State private var axTrusted = false
    @State private var micStatus: AVAuthorizationStatus = .notDetermined

    var onComplete: () -> Void

    private var o: OnboardingLocalization { OnboardingLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private var obGeneralL10n: SettingsLocalization { SettingsLocalization(useChinese: AppUILanguage.isChinese(uiLanguage)) }
    private let stepCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(o.windowTitle)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 8)

            Text("\(step + 1) / \(stepCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)

            Divider()
                .padding(.vertical, 12)

            HStack {
                Button(o.skip) {
                    onComplete()
                }

                Spacer()

                if step > 0 {
                    Button(o.back) {
                        step -= 1
                    }
                }

                Button(step == stepCount - 1 ? o.done : o.next) {
                    if step == stepCount - 1 {
                        onComplete()
                    } else {
                        step += 1
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 480)
        .onAppear {
            SpeechTranscriptionSettings.migrateUserDefaultsIfNeeded()
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            Text(o.stepWelcomeTitle).font(.headline)
            Text(o.stepWelcomeBody).fixedSize(horizontal: false, vertical: true)
        case 1:
            Text(o.stepAXTitle).font(.headline)
            Text(o.stepAXBody).fixedSize(horizontal: false, vertical: true)
            statusRow(ok: axTrusted, okText: o.stepAXStatusOn, badText: o.stepAXStatusOff)
            Button(o.stepAXOpen) {
                TextInjector.openSystemAccessibilitySettings()
            }
            pathSnippet
        case 2:
            Text(o.stepUsualLanguageTitle).font(.headline)
            Text(o.stepUsualLanguageBody).fixedSize(horizontal: false, vertical: true)
            if !speechTranscriptionAutoDetect {
                Picker(SpeechTranscriptionSettings.userFacingLabel(useChinese: AppUILanguage.isChinese(uiLanguage)), selection: $speechTranscriptionLanguageCode) {
                    ForEach(WhisperTranscriptionLanguageCatalog.pickerRows, id: \.code) { row in
                        Text(row.label).tag(row.code)
                    }
                }
                .padding(.top, 4)
                Text(obGeneralL10n.speechRecognitionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Toggle(obGeneralL10n.speechAutoDetectLabel, isOn: $speechTranscriptionAutoDetect)
                .padding(.top, 6)
            Text(obGeneralL10n.speechAutoDetectCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case 3:
            Text(o.stepWhisperTitle).font(.headline)
            Text(o.stepWhisperBody).fixedSize(horizontal: false, vertical: true)
            Text(o.stepWhisperCurrentLabel + whisperKitModelId)
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
            Button(o.stepShortcutOpenSettings) {
                SettingsOpener.open()
            }
        case 4:
            Text(o.stepShortcutTitle).font(.headline)
            Text(o.stepShortcutBody).fixedSize(horizontal: false, vertical: true)
            Button(o.stepShortcutOpenSettings) {
                SettingsOpener.open()
            }
        case 5:
            Text(o.stepOutputModesTitle).font(.headline)
            Text(o.stepOutputModesBody).fixedSize(horizontal: false, vertical: true)
            Button(o.stepOutputModesOpenSettings) {
                SettingsTab.requestSelectTab(SettingsTab.outputModes)
                SettingsWindowHelper.activateForSettingsPanel()
                SettingsOpener.open()
                SettingsWindowHelper.bringSettingsWindowToFront()
            }
        default:
            EmptyView()
        }
    }

    private var pathSnippet: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(o.pathLabel).font(.caption).foregroundStyle(.secondary)
            Text(TextInjector.currentExecutablePathForDiagnostics)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func statusRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(ok ? okText : badText)
                .font(.subheadline)
        }
    }

    private func refreshStatus() {
        axTrusted = TextInjector.isAccessibilityTrustedForCurrentProcess()
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:  micStatus = .authorized
            case .denied:   micStatus = .denied
            default:        micStatus = .notDetermined
            }
        } else {
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

}
