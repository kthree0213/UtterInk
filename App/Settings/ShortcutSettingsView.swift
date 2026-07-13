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
        } catch {
            failureMessage = "Shortcut mode could not be saved. Your current mode was kept."
        }
        isSaving = false
    }

    func resetShortcut() {
        hotkey.reset()
        hotkey.reconfigure(mode: mode)
        refreshHotkeyState()
    }

    func recorderDidChange(hasShortcut: Bool) {
        hotkey.reconfigure(mode: mode)
        refreshHotkeyState()
        hasConfiguredShortcut = hasShortcut
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
                Label(
                    model.shortcutStatus,
                    systemImage: model.hasConfiguredShortcut ? "keyboard.fill" : "keyboard"
                )
                if let conflictMessage = model.conflictMessage {
                    Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Button("Reset Shortcut", action: model.resetShortcut)
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
            }
        }
        .formStyle(.grouped)
        .disabled(model.isSaving)
        .navigationTitle("Shortcuts")
        .task { await model.load() }
    }
}
