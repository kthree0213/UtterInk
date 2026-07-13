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

    private(set) var launchAtLoginEnabled = false
    private(set) var showFloatingRecorder = UserSettings.p0Default.showFloatingRecorder
    private(set) var deliveryPreference = UserSettings.p0Default.deliveryPreference
    private(set) var isSaving = false
    private(set) var failureMessage: String?

    let failureSymbol = "exclamationmark.triangle.fill"

    @ObservationIgnored private let writer: SettingsMutationCoordinator
    @ObservationIgnored private let controller: any DictationControlling
    @ObservationIgnored private let launchAtLogin: any LaunchAtLoginManaging
    @ObservationIgnored private let setFloatingRecorderVisibility: @MainActor (Bool) -> Void

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

    func setDeliveryPreference(_ preference: DeliveryPreference) async {
        guard !isSaving, preference != deliveryPreference else { return }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await writer.update { $0.deliveryPreference = preference }
            deliveryPreference = saved.deliveryPreference
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
                Text(model.launchAtLoginStatus)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Show Floating Recorder",
                    isOn: Binding(
                        get: { model.showFloatingRecorder },
                        set: { value in Task { await model.setFloatingRecorderEnabled(value) } }
                    )
                )
            }
            .disabled(model.isSaving)

            Section("History") {
                Toggle(
                    "Save History",
                    isOn: Binding(
                        get: { model.historyEnabled },
                        set: model.setHistoryEnabled
                    )
                )
                Text("Turning History off keeps existing saved results until you choose Clear History.")
                    .foregroundStyle(.secondary)
                Button("Clear History", role: .destructive) { confirmsClear = true }
                if model.historyControlIsPending {
                    Label("Applying history privacy change…", systemImage: "clock")
                }
                if let warning = model.historyControlWarning {
                    Label(warning, systemImage: model.failureSymbol)
                        .foregroundStyle(.red)
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .task { await model.load() }
        .confirmationDialog(
            "Clear all saved and in-memory history?",
            isPresented: $confirmsClear
        ) {
            Button("Clear History", role: .destructive, action: model.clearHistory)
        }
    }
}
