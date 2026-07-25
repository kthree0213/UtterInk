import Accessibility
import AppKit
import SwiftUI
import UtterInkCore

@MainActor
enum FrontmostWindowPresenter {
    static func present(_ action: () -> Void) {
        let menuWindow = NSApplication.shared.keyWindow
        let windowsBeforeAction = Set(
            NSApplication.shared.windows.map(ObjectIdentifier.init)
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        action()

        Task { @MainActor in
            await Task.yield()
            bringForward(
                excluding: menuWindow,
                preferringWindowsNotIn: windowsBeforeAction
            )
            for delay in [80, 180, 320] {
                try? await Task.sleep(for: .milliseconds(delay))
                bringForward(
                    excluding: menuWindow,
                    preferringWindowsNotIn: windowsBeforeAction
                )
            }
        }
    }

    private static func bringForward(
        excluding menuWindow: NSWindow?,
        preferringWindowsNotIn previousWindowIDs: Set<ObjectIdentifier>
    ) {
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        let candidates = application.orderedWindows.filter {
            $0 !== menuWindow
                && $0.isVisible
                && $0.canBecomeKey
                && $0.styleMask.contains(.titled)
        }
        guard let target = candidates.first(where: {
            !previousWindowIDs.contains(ObjectIdentifier($0))
        }) ?? candidates.first else { return }
        target.makeKeyAndOrderFront(nil)
        target.orderFrontRegardless()
    }
}

@MainActor
enum MenuBarFocusReturn {
    static func perform(_ action: () -> Void) {
        let menuWindow = NSApplication.shared.keyWindow
        action()
        menuWindow?.orderOut(nil)
    }
}

struct MenuBarRootView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel

    private let settingsStore: (any SettingsStore)?
    private let openHistory: (() -> Void)?
    private let openLastResult: (() -> Void)?
    private let openOnboarding: (() -> Void)?
    private let settingsNavigation: SettingsNavigationModel?

    @State private var settings = UserSettings.p0Default
    @State private var isSavingOutputMode = false
    @State private var outputSaveWarning: String?

    init(
        model: AppModel,
        settingsStore: (any SettingsStore)?,
        openHistory: (() -> Void)? = nil,
        openLastResult: (() -> Void)? = nil,
        openOnboarding: (() -> Void)? = nil,
        settingsNavigation: SettingsNavigationModel? = nil
    ) {
        self.model = model
        self.settingsStore = settingsStore
        self.openHistory = openHistory
        self.openLastResult = openLastResult
        self.openOnboarding = openOnboarding
        self.settingsNavigation = settingsNavigation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                sessionContent

                if model.readiness == .ready {
                    if model.latestResult != nil {
                        Divider()
                        latestResultContent
                    }
                    Divider()
                    configurationContent
                }
            }
            .padding(12)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if model.readiness == .ready {
                    routeContent
                    Divider()
                }

                Button {
                    FrontmostWindowPresenter.present {
                        openSettings()
                    }
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
        .fixedSize(horizontal: false, vertical: true)
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
    private var sessionContent: some View {
        switch model.readiness {
        case .pending, .failed:
            statusContent
        case .ready:
            switch model.pipeline.stage {
            case .idle, .completed, .failed:
                Button {
                    MenuBarFocusReturn.perform {
                        model.start()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Label(EnglishCopy.start, systemImage: "waveform")
                        Spacer(minLength: 12)
                        Text(EnglishCopy.startShortcut)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("menu.shortcutHint")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("menu.start")
                .help("Start listening with the menu or Right Option")
            case .requestingPermission, .recording, .stopping, .transcribing,
                 .polishing, .delivering:
                statusContent
                actionContent
            }
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
                MenuBarFocusReturn.perform {
                    model.start()
                }
            } label: {
                Label(EnglishCopy.start, systemImage: "text.cursor")
            }
            .accessibilityIdentifier("menu.start")
            .help(EnglishCopy.start)
        case .stop:
            Button {
                MenuBarFocusReturn.perform {
                    model.stop()
                }
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
        if let result = model.latestResult {
            Button {
                FrontmostWindowPresenter.present {
                    if let openLastResult {
                        openLastResult()
                    } else {
                        openWindow(id: AppWindowID.lastResult)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(EnglishCopy.latestResult)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(result.finalText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open latest result")
            .accessibilityValue(result.finalText)
                .accessibilityIdentifier("menu.latestResult")
                .help(EnglishCopy.viewLatestResult)

            if let warning = resultWarningText(for: result) {
                Label(
                    warning,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .accessibilityLabel("Warning")
                .accessibilityValue(warning)
                .accessibilityIdentifier("menu.resultWarning")
            }

            HStack(spacing: 8) {
                Button {
                    model.copyResult(result.sessionID)
                } label: {
                    Label(EnglishCopy.copyResult, systemImage: "doc.on.doc")
                }
                .disabled(!canRecoverResult)
                .accessibilityIdentifier("menu.copyLatest")
                .help(EnglishCopy.copyLatestResult)

                if needsPasteRecovery(result) {
                    Button {
                        MenuBarFocusReturn.perform {
                            model.pasteAgain(result.sessionID)
                        }
                    } label: {
                        Label(EnglishCopy.pasteLatestResult, systemImage: "arrow.up.doc")
                    }
                    .disabled(!canRecoverResult)
                    .accessibilityIdentifier("menu.pasteLatest")
                    .help(EnglishCopy.pasteLatestResult)
                }
            }
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
                .accessibilityLabel("Notice")
                .accessibilityValue(outputSaveWarning)
                .accessibilityIdentifier("menu.outputModeError")
        }

    }

    @ViewBuilder
    private var routeContent: some View {
        Button {
            FrontmostWindowPresenter.present {
                if let openHistory {
                    openHistory()
                } else {
                    openWindow(id: AppWindowID.history)
                }
            }
        } label: {
            Label(EnglishCopy.history, systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("menu.history")
        .help(EnglishCopy.history)

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

    private func needsPasteRecovery(_ result: DictationResult) -> Bool {
        FloatingCompletionPolicy.requiresPasteRecovery(
            stage: model.pipeline.stage,
            result: result
        )
    }

    private func resultWarningText(for result: DictationResult) -> String? {
        if model.pipeline.result?.sessionID == result.sessionID,
           let warning = stagePresentation.warning {
            return warning
        }
        return result.warning.map { EnglishCopy.warning(for: $0) }
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
                let current = try await settingsStore.current()
                settings = current
                guard let mode = current.outputModes.first(where: { $0.id == id }) else {
                    outputSaveWarning = "That output mode is no longer available."
                    return
                }
                if mode.requiresProvider, !Self.hasConfiguredProvider(in: current) {
                    outputSaveWarning = "Set up an AI Provider before using \(mode.title)."
                    FrontmostWindowPresenter.present {
                        settingsNavigation?.show(.provider)
                        openSettings()
                    }
                    return
                }
                settings = try await settingsStore.update {
                    $0.selectedOutputModeID = id
                }
            } catch {
                outputSaveWarning = EnglishCopy.outputSaveFailed
            }
        }
    }

    private static func hasConfiguredProvider(in settings: UserSettings) -> Bool {
        guard let selectedID = settings.selectedProviderProfileID else { return false }
        return settings.providerProfiles.contains(where: { $0.id == selectedID })
    }
}
