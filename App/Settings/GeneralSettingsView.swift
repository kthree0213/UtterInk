import Observation
import SwiftUI
import UtterInkCore

@MainActor
@Observable
final class GeneralSettingsViewModel {
    static let automaticPasteExplanation =
        "Automatic Paste validates the original target before sending Command-V, then restores the prior clipboard only when guarded restoration remains safe. If delivery cannot proceed safely, the result remains available for explicit Copy."
    static let copyOnlyExplanation =
        "Copy Only uses your snapshotted pre-authorization to replace the clipboard with each completed dictation. It does not send Command-V and does not automatically restore the previous clipboard."
    static let safetyFallbackExplanation =
        "When automatic delivery is unsafe, UtterInk keeps the result available and waits for you to choose Copy; it does not claim the text was copied."
    static let historyRetentionExplanation =
        "Keep up to 20 recent dictations on this Mac, including original and polished text when available. Audio is never kept in History."
    static let historyDisabledExplanation =
        "Turning this off stops saving new dictations. Existing history remains until cleared."
    static let historyClearExplanation =
        "This deletes original and polished text from this Mac. This can’t be undone."

    private(set) var launchAtLoginEnabled = false
    private(set) var showFloatingRecorder = UserSettings.p0Default.showFloatingRecorder
    private(set) var deliveryPreference = UserSettings.p0Default.deliveryPreference
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?

    let failureSymbol = "exclamationmark.triangle.fill"

    @ObservationIgnored private let writer: SettingsMutationCoordinator
    @ObservationIgnored private let controller: any DictationControlling
    @ObservationIgnored private let launchAtLogin: any LaunchAtLoginManaging
    @ObservationIgnored private let setFloatingRecorderVisibility: @MainActor (Bool) -> Void
    @ObservationIgnored private var replayOnboardingHandler: @MainActor () -> Void = {}

    init(
        settings: any SettingsStore,
        controller: any DictationControlling,
        launchAtLogin: any LaunchAtLoginManaging,
        setFloatingRecorderEnabled: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.writer = SettingsMutationCoordinator(store: settings)
        self.controller = controller
        self.launchAtLogin = launchAtLogin
        self.setFloatingRecorderVisibility = setFloatingRecorderEnabled
    }

    init(
        settings: any SettingsStore,
        writer: SettingsMutationCoordinator,
        controller: any DictationControlling,
        launchAtLogin: any LaunchAtLoginManaging,
        setFloatingRecorderEnabled: @escaping @MainActor (Bool) -> Void
    ) {
        self.writer = writer
        self.controller = controller
        self.launchAtLogin = launchAtLogin
        self.setFloatingRecorderVisibility = setFloatingRecorderEnabled
    }

    var launchAtLoginStatus: String {
        switch launchAtLogin.state {
        case .disabled: return "Off"
        case .enabled: return "On"
        case .requiresApproval: return "Approval Required"
        case .unavailable: return "Unavailable"
        case .failed: return "Failed"
        }
    }

    var deliveryExplanation: String {
        deliveryPreference == .automaticPaste
            ? Self.automaticPasteExplanation
            : Self.copyOnlyExplanation
    }

    var historyEnabled: Bool { controller.historyControlStatus.enabled }

    var historyControlIsPending: Bool {
        controller.historyControlStatus.isPending
    }

    private var savedHistorySessionIDs: Set<SessionID> {
        Set(controller.historyRecords.map(\.sessionID))
    }

    private var unsavedResultSessionIDs: Set<SessionID> {
        Set(controller.volatileResults.map(\.sessionID))
            .subtracting(savedHistorySessionIDs)
    }

    var savedHistoryItemCount: Int {
        savedHistorySessionIDs.count
    }

    var unsavedResultItemCount: Int {
        unsavedResultSessionIDs.count
    }

    var clearableResultItemCount: Int {
        savedHistoryItemCount + unsavedResultItemCount
    }

    var historyItemSummary: String {
        let savedSummary: String
        if savedHistoryItemCount == 0, historyClearNeedsRetry {
            savedSummary = "Saved history still needs clearing"
        } else {
            switch savedHistoryItemCount {
            case 0:
                savedSummary = "No saved dictations"
            case 1:
                savedSummary = "1 saved dictation"
            case let count:
                savedSummary = "\(count) saved dictations"
            }
        }

        switch unsavedResultItemCount {
        case 0:
            return savedSummary
        case 1:
            return "\(savedSummary) · 1 unsaved result available until quit"
        case let count:
            return "\(savedSummary) · \(count) unsaved results available until quit"
        }
    }

    var canClearHistory: Bool {
        (clearableResultItemCount > 0 || historyClearNeedsRetry) && !historyControlIsPending
    }

    var clearHistoryConfirmationTitle: String {
        let count = clearableResultItemCount
        if count == 0, historyClearNeedsRetry {
            return "Try clearing saved history again?"
        }

        if unsavedResultItemCount > 0 {
            return count == 1
                ? "Clear 1 result?"
                : "Clear \(count) results?"
        }

        return count == 1
            ? "Clear 1 saved dictation?"
            : "Clear \(count) saved dictations?"
    }

    private var historyClearNeedsRetry: Bool {
        guard case .failed(_, .clearFailed) = controller.historyControlStatus else {
            return false
        }
        return true
    }

    var historyControlWarning: String? {
        guard case let .failed(_, failure) = controller.historyControlStatus else {
            return nil
        }
        switch failure {
        case .applyFailed:
            return "History could not be changed. The previous privacy setting is still active."
        case .preferenceSaveFailed:
            return "History changed for this run, but the preference could not be saved. It may differ after UtterInk restarts."
        case .clearFailed:
            return "History disappeared from this window, but its saved records could not be cleared."
        }
    }

    var historyAccessibilityAnnouncement: String? {
        switch controller.historyControlStatus {
        case let .applying(enabled):
            return "Applying History \(enabled ? "on" : "off") setting."
        case .clearing:
            return "Clearing History."
        case let .settled(enabled):
            return "History is now \(enabled ? "on" : "off")."
        case .failed:
            return nil
        }
    }

    func load() async {
        guard !isSaving else { return }
        launchAtLogin.refresh()
        do {
            let value = try await writer.current()
            launchAtLoginEnabled = launchAtLogin.state == .enabled
            showFloatingRecorder = value.showFloatingRecorder
            deliveryPreference = value.deliveryPreference
            failureMessage = nil
        } catch {
            failureMessage = "Settings could not be loaded. Your current values were kept."
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        guard !isSaving, enabled != launchAtLoginEnabled else { return }
        isSaving = true
        failureMessage = nil
        let previous = launchAtLoginEnabled
        await launchAtLogin.setEnabled(enabled)
        guard (launchAtLogin.state == .enabled) == enabled,
              launchAtLogin.state != .requiresApproval,
              launchAtLogin.state != .failed,
              launchAtLogin.state != .unavailable else {
            failureMessage = launchAtLogin.state == .requiresApproval
                ? "Allow UtterInk in System Settings to launch at login."
                : "Launch at login could not be changed. Your current setting was kept."
            isSaving = false
            return
        }
        do {
            let saved = try await writer.update { $0.launchAtLogin = enabled }
            launchAtLoginEnabled = saved.launchAtLogin
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Launch at Login is now \(saved.launchAtLogin ? "on" : "off")."
            )
        } catch {
            await launchAtLogin.setEnabled(previous)
            launchAtLoginEnabled = launchAtLogin.state == .enabled
            failureMessage = "Launch at login could not be saved. Your current setting was kept."
        }
        isSaving = false
    }

    func setFloatingRecorderEnabled(_ enabled: Bool) async {
        guard !isSaving, enabled != showFloatingRecorder else { return }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await writer.update { $0.showFloatingRecorder = enabled }
            showFloatingRecorder = saved.showFloatingRecorder
            setFloatingRecorderVisibility(saved.showFloatingRecorder)
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Floating recorder is now \(saved.showFloatingRecorder ? "on" : "off")."
            )
        } catch {
            failureMessage = "Floating recorder visibility could not be saved. Your current setting was kept."
        }
        isSaving = false
    }

    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled != historyEnabled else { return }
        controller.send(.setHistoryEnabled(enabled))
    }

    func clearHistory() {
        controller.send(.clearHistory)
    }

    func setReplayOnboardingHandler(_ handler: @escaping @MainActor () -> Void) {
        replayOnboardingHandler = handler
    }

    func replayOnboarding() {
        replayOnboardingHandler()
    }

    func setDeliveryPreference(_ preference: DeliveryPreference) async {
        guard !isSaving, preference != deliveryPreference else { return }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await writer.update { $0.deliveryPreference = preference }
            deliveryPreference = saved.deliveryPreference
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: saved.deliveryPreference == .automaticPaste
                    ? "Delivery preference saved: Automatic Paste."
                    : "Delivery preference saved: Copy Only."
            )
        } catch {
            failureMessage = "Delivery preference could not be saved. Your current setting was kept."
        }
        isSaving = false
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettingsViewModel
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { value in Task { await model.setLaunchAtLoginEnabled(value) } }
                    )
                )
                .accessibilityLabel("Launch at Login")
                .accessibilityIdentifier("settings.general.launchAtLogin")
                Text(model.launchAtLoginStatus)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Launch at Login status")
                    .accessibilityValue(model.launchAtLoginStatus)
                    .accessibilityIdentifier("settings.general.launchAtLoginStatus")
                Toggle(
                    "Show Recording Overlay",
                    isOn: Binding(
                        get: { model.showFloatingRecorder },
                        set: { value in Task { await model.setFloatingRecorderEnabled(value) } }
                    )
                )
                .accessibilityLabel("Show Recording Overlay")
                .accessibilityIdentifier("settings.general.floatingRecorder")
            }
            .disabled(model.isSaving)

            Section("History") {
                Toggle(
                    "Save Recent History",
                    isOn: Binding(
                        get: { model.historyEnabled },
                        set: model.setHistoryEnabled
                    )
                )
                .accessibilityLabel("Save Recent History")
                .accessibilityIdentifier("settings.general.historyEnabled")
                VStack(alignment: .leading, spacing: 6) {
                    Text(GeneralSettingsViewModel.historyRetentionExplanation)
                    Text(GeneralSettingsViewModel.historyDisabledExplanation)
                }
                .foregroundStyle(.secondary)
                HStack {
                    Text(model.historyItemSummary)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved history")
                        .accessibilityValue(model.historyItemSummary)
                        .accessibilityIdentifier("settings.general.historySummary")
                    Spacer()
                    Button("Clear History…", role: .destructive) { confirmsClear = true }
                        .disabled(!model.canClearHistory)
                        .accessibilityHint("Deletes all text in History from this Mac")
                        .accessibilityIdentifier("settings.general.clearHistory")
                }
                if model.historyControlIsPending {
                    Label("Applying history privacy change…", systemImage: "clock")
                        .accessibilityLabel("History status")
                        .accessibilityValue("Applying privacy change")
                        .accessibilityIdentifier("settings.general.historyStatus")
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if let warning = model.historyControlWarning {
                    Label(warning, systemImage: model.failureSymbol)
                        .foregroundStyle(.red)
                        .accessibilityLabel("History error")
                        .accessibilityValue(warning)
                        .accessibilityIdentifier("settings.general.historyError")
                }
            }

            Section("Delivery") {
                Picker(
                    "Completed Dictations",
                    selection: Binding(
                        get: { model.deliveryPreference },
                        set: { value in Task { await model.setDeliveryPreference(value) } }
                    )
                ) {
                    Text("Automatic Paste").tag(DeliveryPreference.automaticPaste)
                    Text("Copy Only").tag(DeliveryPreference.copyOnly)
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Completed Dictations")
                .accessibilityIdentifier("settings.general.deliveryPreference")
                Text(model.deliveryExplanation)
                    .foregroundStyle(.secondary)
                Label(
                    GeneralSettingsViewModel.safetyFallbackExplanation,
                    systemImage: "hand.raised.fill"
                )
            }
            .disabled(model.isSaving)

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: model.failureSymbol)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("settings.general.error")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Section("Getting Started") {
                Button {
                    model.replayOnboarding()
                } label: {
                    Label("Run Onboarding Again", systemImage: "list.number")
                }
                .buttonStyle(.link)
                .accessibilityLabel("Run Onboarding Again")
                .accessibilityIdentifier("settings.general.replayOnboarding")

                Text("Review privacy, permissions, the shortcut, and a local test dictation. Your current settings stay in place.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.general")
        .utterInkAccessibilityAnnouncement(
            (model.failureMessage ?? model.historyControlWarning).map { "Error: \($0)" }
        )
        .utterInkAccessibilityAnnouncement(model.historyAccessibilityAnnouncement)
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .navigationTitle("General")
        .task { await model.load() }
        .confirmationDialog(
            model.clearHistoryConfirmationTitle,
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: model.clearHistory)
                .accessibilityIdentifier("settings.general.confirmClearHistory")
        } message: {
            Text(GeneralSettingsViewModel.historyClearExplanation)
        }
    }
}
