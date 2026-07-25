import AppKit
import Foundation
import UtterInkCore
import UtterInkServices

enum SystemSettingsDestination: Equatable, Sendable {
    case microphone
    case accessibility
}

@MainActor
protocol SystemSettingsNavigating: AnyObject {
    func open(_ destination: SystemSettingsDestination)
}

enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
    case failed
}

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var state: LaunchAtLoginState { get }
    func refresh()
    func setEnabled(_ enabled: Bool) async
}

@MainActor
protocol HotkeyProbing: AnyObject {
    func arm() async -> AsyncStream<Void>
    func armProbeOnly() async -> AsyncStream<Void>
}

extension HotkeyProbing {
    func armProbeOnly() async -> AsyncStream<Void> {
        await arm()
    }
}

@MainActor
protocol HotkeyConfiguring: AnyObject {
    var currentMode: ShortcutMode { get }
    var hasConflict: Bool { get }
    var hasConfiguredShortcut: Bool { get }
    var usesDefaultRightOption: Bool { get }
    var shortcutDescription: String { get }
    func reconfigure(mode: ShortcutMode)
    func reset()
}

@MainActor
protocol DiagnosticsExporting: AnyObject {
    func export(_ snapshot: DiagnosticsSnapshot) -> Data
}

@MainActor
final class SystemSettingsNavigator: SystemSettingsNavigating {
    func open(_ destination: SystemSettingsDestination) {
        let pane: String
        switch destination {
        case .microphone:
            pane = "Privacy_Microphone"
        case .accessibility:
            pane = "Privacy_Accessibility"
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class SafeDiagnosticsExporter: DiagnosticsExporting {
    private let exporter: DiagnosticsExporter

    init(exporter: DiagnosticsExporter = DiagnosticsExporter()) {
        self.exporter = exporter
    }

    func export(_ snapshot: DiagnosticsSnapshot) -> Data {
        exporter.export(snapshot)
    }
}

@MainActor
final class LazyHotkeyService: HotkeyProbing, HotkeyConfiguring {
    typealias EventHandler = @MainActor @Sendable (
        ShortcutMode,
        KeyboardShortcutsHotkeyService.Event
    ) -> Void

    private let settings: any SettingsStore
    private let eventHandler: EventHandler
    private var service: KeyboardShortcutsHotkeyService?

    private(set) var currentMode: ShortcutMode = .toggle
    private(set) var hasConflict = false

    var hasConfiguredShortcut: Bool {
        KeyboardShortcutsHotkeyService.hasConfiguredShortcut
    }

    var usesDefaultRightOption: Bool {
        KeyboardShortcutsHotkeyService.usesDefaultRightOption
    }

    var shortcutDescription: String {
        KeyboardShortcutsHotkeyService.shortcutDescription
    }

    init(
        settings: any SettingsStore,
        eventHandler: @escaping EventHandler
    ) {
        self.settings = settings
        self.eventHandler = eventHandler
    }

    func arm() async -> AsyncStream<Void> {
        let service = await ensureService()
        return service?.probeEvents() ?? Self.finishedStream()
    }

    func armProbeOnly() async -> AsyncStream<Void> {
        let service = await ensureService()
        return service?.probeEvents(suppressingCommand: true) ?? Self.finishedStream()
    }

    private func ensureService() async -> KeyboardShortcutsHotkeyService? {
        if service == nil {
            currentMode = (try? await settings.current().shortcutMode) ?? .toggle
            let service = KeyboardShortcutsHotkeyService(
                mode: currentMode,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    self.eventHandler(self.currentMode, event)
                }
            )
            self.service = service
            hasConflict = service.hasConflict
        }
        return service
    }

    func reset() {
        KeyboardShortcutsHotkeyService.resetShortcut()
        service?.teardown()
        let service = makeService(mode: currentMode)
        self.service = service
        hasConflict = service.hasConflict
    }

    func reconfigure(mode: ShortcutMode) {
        service?.teardown()
        currentMode = mode
        let service = makeService(mode: mode)
        self.service = service
        hasConflict = service.hasConflict
    }

    private func makeService(mode: ShortcutMode) -> KeyboardShortcutsHotkeyService {
        KeyboardShortcutsHotkeyService(
            mode: mode,
            onEvent: { [weak self] event in
                guard let self else { return }
                self.eventHandler(self.currentMode, event)
            }
        )
    }

    private static func finishedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}
