import Accessibility
import AppKit
import SwiftUI
import UtterInkCore

struct MenuBarRootView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel

    private let settingsStore: (any SettingsStore)?
    private let openHistory: (() -> Void)?
    private let openLastResult: (() -> Void)?
    private let openOnboarding: (() -> Void)?

    @State private var settings = UserSettings.p0Default
    @State private var isSavingOutputMode = false
    @State private var outputSaveWarning: String?

    init(
        model: AppModel,
        settingsStore: (any SettingsStore)?,
        openHistory: (() -> Void)? = nil,
        openLastResult: (() -> Void)? = nil,
        openOnboarding: (() -> Void)? = nil
    ) {
        self.model = model
        self.settingsStore = settingsStore
        self.openHistory = openHistory
        self.openLastResult = openLastResult
        self.openOnboarding = openOnboarding
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                statusContent
                Divider()

                if model.readiness == .ready {
                    actionContent
                    Divider()
                    latestResultContent
                    Divider()
                    configurationContent
                    Divider()
                    routeContent
                }

                Button {
                    openSettings()
                } label: {
                    Label(EnglishCopy.settings, systemImage: "gearshape")
                }
                .accessibilityIdentifier("menu.settings")
                .help("Open UtterInk Settings")

                Divider()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(EnglishCopy.quit, systemImage: "xmark")
                }
                .accessibilityIdentifier("menu.quit")
                .help(EnglishCopy.quit)
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: 640)
        .task {
            guard let settingsStore,
                  let loaded = try? await settingsStore.current() else { return }
            settings = loaded
        }
        .onChange(of: outputSaveWarning) { _, warning in
            guard let warning else { return }
            AccessibilityNotification.Announcement("Error: \(warning)").post()
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch model.readiness {
        case .pending:
            Label(EnglishCopy.starting, systemImage: "clock")
                .accessibilityLabel(EnglishCopy.status)
                .accessibilityValue(EnglishCopy.starting)
                .accessibilityIdentifier("menu.status")
                .accessibilityAddTraits(.updatesFrequently)
        case .failed:
            Label(EnglishCopy.unavailable, systemImage: "exclamationmark.triangle.fill")
                .accessibilityLabel(EnglishCopy.status)
                .accessibilityValue(EnglishCopy.appUnavailable)
                .accessibilityIdentifier("menu.status")
                .accessibilityAddTraits(.updatesFrequently)
            Text(EnglishCopy.appUnavailable)
                .accessibilityHidden(true)
        case .ready:
            let presentation = stagePresentation
            Label(presentation.label, systemImage: presentation.systemImage)
                .accessibilityLabel(EnglishCopy.status)
                .accessibilityValue(presentation.label)
                .accessibilityIdentifier("menu.status")
                .accessibilityAddTraits(.updatesFrequently)

            if let warning = presentation.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .accessibilityLabel("Warning")
                    .accessibilityValue(warning)
                    .accessibilityIdentifier("menu.warning")
            } else if model.pipeline.stage == .completed {
                Label(EnglishCopy.resultSuccess, systemImage: "checkmark")
                    .accessibilityLabel("Result")
                    .accessibilityValue(EnglishCopy.resultSuccess)
            }
        }
    }

    @ViewBuilder
    private var actionContent: some View {
        switch stagePresentation.primaryAction {
        case .start:
            Button {
                model.start()
            } label: {
                Label(EnglishCopy.start, systemImage: "text.cursor")
            }
            .accessibilityIdentifier("menu.start")
            .help(EnglishCopy.start)
        case .stop:
            Button {
                model.stop()
            } label: {
                Label(EnglishCopy.stop, systemImage: "square")
            }
            .accessibilityIdentifier("menu.stop")
            .help(EnglishCopy.stop)
        case .none:
            EmptyView()
        }

        switch stagePresentation.secondaryAction {
        case .cancel:
            Button {
                model.performEscape()
            } label: {
                Label(EnglishCopy.cancel, systemImage: "xmark")
            }
            .accessibilityIdentifier("menu.cancel")
            .help("Cancel the active dictation")
        case .dismiss:
            Button {
                model.acknowledge()
            } label: {
                Label(EnglishCopy.dismiss, systemImage: "xmark")
            }
            .accessibilityIdentifier("menu.dismiss")
            .help("Dismiss the finished dictation")
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var latestResultContent: some View {
        Text(EnglishCopy.latestResult)

        if let result = model.latestResult {
            Text(result.finalText)
                .lineLimit(3)
                .accessibilityIdentifier("menu.latestResult")
                .help("Latest dictation result")

            if let warning = result.warning {
                Label(
                    EnglishCopy.warning(for: warning),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .accessibilityLabel("Warning")
                .accessibilityValue(EnglishCopy.warning(for: warning))
                .accessibilityIdentifier("menu.resultWarning")
            }

            Button {
                model.copyResult(result.sessionID)
            } label: {
                Label(EnglishCopy.copyLatestResult, systemImage: "doc.on.doc")
            }
            .disabled(!canRecoverResult)
            .accessibilityIdentifier("menu.copyLatest")
            .help(EnglishCopy.copyLatestResult)

            Button {
                model.pasteAgain(result.sessionID)
            } label: {
                Label(EnglishCopy.pasteLatestResult, systemImage: "arrow.up.doc")
            }
            .disabled(!canRecoverResult)
            .accessibilityIdentifier("menu.pasteLatest")
            .help(EnglishCopy.pasteLatestResult)

            Button {
                if let openLastResult {
                    openLastResult()
                } else {
                    openWindow(id: AppWindowID.lastResult)
                }
            } label: {
                Label(EnglishCopy.viewLatestResult, systemImage: "rectangle.on.rectangle")
            }
            .accessibilityIdentifier("menu.viewLatest")
            .help(EnglishCopy.viewLatestResult)
        } else {
            Text(EnglishCopy.noRecentResult)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var configurationContent: some View {
        Menu {
            ForEach(rawFirstOutputModes) { mode in
                Button {
                    selectOutputMode(mode.id)
                } label: {
                    if mode.id == settings.selectedOutputModeID {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label(
                "\(EnglishCopy.output): \(selectedOutputTitle)",
                systemImage: "text.badge.checkmark"
            )
        }
        .disabled(settingsStore == nil || isSavingOutputMode)
        .accessibilityIdentifier("menu.outputMode")
        .accessibilityValue(selectedOutputTitle)

        if let outputSaveWarning {
            Label(outputSaveWarning, systemImage: "exclamationmark.triangle.fill")
                .accessibilityLabel("Error")
                .accessibilityValue(outputSaveWarning)
                .accessibilityIdentifier("menu.outputModeError")
        }

        Label(
            "\(EnglishCopy.recognitionLanguage): \(EnglishCopy.recognition(settings.recognition))",
            systemImage: "character.cursor.ibeam"
        )
        Label(
            "\(EnglishCopy.speechModel): \(EnglishCopy.speechModel(model.speechModel))",
            systemImage: "internaldrive"
        )
    }

    @ViewBuilder
    private var routeContent: some View {
        Button {
            if let openHistory {
                openHistory()
            } else {
                openWindow(id: AppWindowID.history)
            }
        } label: {
            Label(EnglishCopy.history, systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("menu.history")
        .help(EnglishCopy.history)

        Button {
            openOnboarding?()
        } label: {
            Label(EnglishCopy.onboarding, systemImage: "list.number")
        }
        .disabled(openOnboarding == nil)
        .accessibilityIdentifier("menu.onboarding")
        .help(
            openOnboarding == nil
                ? EnglishCopy.onboardingUnavailable
                : EnglishCopy.onboarding
        )
    }

    private var stagePresentation: StagePresentation {
        StagePresentation(
            state: model.pipeline,
            sessionPresentation: model.sessionPresentation
        )
    }

    private var canRecoverResult: Bool {
        switch model.pipeline.stage {
        case .idle, .completed, .failed:
            return true
        default:
            return false
        }
    }

    private var rawFirstOutputModes: [OutputMode] {
        let configured = settings.outputModes
        let raw = configured.first { $0.id == OutputMode.rawID } ?? .raw
        return [raw] + configured.filter { $0.id != OutputMode.rawID }
    }

    private var selectedOutputTitle: String {
        rawFirstOutputModes.first { $0.id == settings.selectedOutputModeID }?.title
            ?? OutputMode.raw.title
    }

    private func selectOutputMode(_ id: UUID) {
        guard let settingsStore,
              !isSavingOutputMode,
              rawFirstOutputModes.contains(where: { $0.id == id }) else { return }
        isSavingOutputMode = true
        outputSaveWarning = nil
        Task { @MainActor in
            defer { isSavingOutputMode = false }
            do {
                settings = try await settingsStore.update {
                    $0.selectedOutputModeID = id
                }
            } catch {
                outputSaveWarning = EnglishCopy.outputSaveFailed
            }
        }
    }
}
