import Observation
import SwiftUI
import UtterInkCore
import UtterInkServices

@MainActor
@Observable
final class ShortcutSettingsViewModel {
    private(set) var mode = UserSettings.p0Default.shortcutMode
    private(set) var hasConfiguredShortcut = false
    private(set) var hasConflict = false
    private(set) var isSaving = false
    private(set) var failureMessage: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?
    let failureSymbol = "exclamationmark.triangle.fill"

    @ObservationIgnored private let writer: SettingsMutationCoordinator
    @ObservationIgnored private let hotkey: any HotkeyConfiguring

    init(settings: any SettingsStore, hotkey: any HotkeyConfiguring) {
        writer = SettingsMutationCoordinator(store: settings)
        self.hotkey = hotkey
    }

    init(
        settings: any SettingsStore,
        writer: SettingsMutationCoordinator,
        hotkey: any HotkeyConfiguring
    ) {
        self.writer = writer
        self.hotkey = hotkey
    }

    var shortcutStatus: String {
        hasConfiguredShortcut ? "Shortcut recorded" : "No shortcut recorded"
    }

    var conflictMessage: String? {
        hasConflict
            ? "This shortcut conflicts with another system or app shortcut."
            : nil
    }

    func load() async {
        guard !isSaving else { return }
        do {
            mode = try await writer.current().shortcutMode
            refreshHotkeyState()
            failureMessage = nil
        } catch {
            failureMessage = "Shortcut settings could not be loaded. Your current values were kept."
        }
    }

    func setMode(_ newMode: ShortcutMode) async {
        guard !isSaving, newMode != mode else { return }
        isSaving = true
        failureMessage = nil
        do {
            let saved = try await writer.update { $0.shortcutMode = newMode }
            mode = saved.shortcutMode
            hotkey.reconfigure(mode: saved.shortcutMode)
            refreshHotkeyState()
            accessibilityEvent = UtterInkAccessibilityEvent(
                message: "Shortcut mode saved: \(saved.shortcutMode == .toggle ? "Toggle" : "Hold to Talk")."
            )
        } catch {
            failureMessage = "Shortcut mode could not be saved. Your current mode was kept."
        }
        isSaving = false
    }

    func resetShortcut() {
        hotkey.reset()
        hotkey.reconfigure(mode: mode)
        refreshHotkeyState()
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: "Shortcut reset. No shortcut recorded."
        )
    }

    func recorderDidChange(hasShortcut: Bool) {
        hotkey.reconfigure(mode: mode)
        refreshHotkeyState()
        hasConfiguredShortcut = hasShortcut
        let base = hasShortcut ? "Shortcut recorded." : "Shortcut cleared."
        accessibilityEvent = UtterInkAccessibilityEvent(
            message: hasConflict
                ? "\(base) Warning: shortcut conflict detected."
                : base
        )
    }

    func refreshHotkeyState() {
        hasConfiguredShortcut = hotkey.hasConfiguredShortcut
        hasConflict = hotkey.hasConflict
    }
}

struct ShortcutSettingsView: View {
    @Bindable var model: ShortcutSettingsViewModel

    var body: some View {
        Form {
            Section("Recorder Shortcut") {
                DictationShortcutRecorder { hasShortcut in
                    model.recorderDidChange(hasShortcut: hasShortcut)
                }
                .accessibilityIdentifier("settings.shortcuts.recorder")
                Label(
                    model.shortcutStatus,
                    systemImage: model.hasConfiguredShortcut ? "keyboard.fill" : "keyboard"
                )
                .accessibilityLabel("Shortcut status")
                .accessibilityValue(model.shortcutStatus)
                .accessibilityIdentifier("settings.shortcuts.status")
                if let conflictMessage = model.conflictMessage {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Shortcut conflict")
                        .accessibilityValue(conflictMessage)
                        .accessibilityIdentifier("settings.shortcuts.conflict")
                }
                Button("Reset Shortcut", action: model.resetShortcut)
                    .accessibilityIdentifier("settings.shortcuts.reset")
            }

            Section("Shortcut Behavior") {
                Picker(
                    "Mode",
                    selection: Binding(
                        get: { model.mode },
                        set: { value in Task { await model.setMode(value) } }
                    )
                ) {
                    Text("Toggle").tag(ShortcutMode.toggle)
                    Text("Hold to Talk").tag(ShortcutMode.holdToTalk)
                }
                .pickerStyle(.radioGroup)
                .accessibilityLabel("Shortcut Mode")
                .accessibilityIdentifier("settings.shortcuts.mode")
                Text(
                    model.mode == .toggle
                        ? "Press once to start and again to stop."
                        : "Hold the shortcut while speaking and release it to stop."
                )
                .foregroundStyle(.secondary)
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: model.failureSymbol)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("settings.shortcuts.error")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.shortcuts")
        .utterInkAccessibilityAnnouncement(
            (model.failureMessage ?? model.conflictMessage).map { "Warning: \($0)" }
        )
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .disabled(model.isSaving)
        .navigationTitle("Shortcuts")
        .task { await model.load() }
    }
}
