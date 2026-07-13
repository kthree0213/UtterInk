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
}

@MainActor
protocol HotkeyConfiguring: AnyObject {
    var currentMode: ShortcutMode { get }
    var hasConflict: Bool { get }
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
    typealias EventHandler = @MainActor @Sendable (KeyboardShortcutsHotkeyService.Event) -> Void

    private let settings: any SettingsStore
    private let eventHandler: EventHandler
    private var service: KeyboardShortcutsHotkeyService?

    private(set) var currentMode: ShortcutMode = .toggle
    private(set) var hasConflict = false

    init(
        settings: any SettingsStore,
        eventHandler: @escaping EventHandler
    ) {
        self.settings = settings
        self.eventHandler = eventHandler
    }

    func arm() async -> AsyncStream<Void> {
        if service == nil {
            currentMode = (try? await settings.current().shortcutMode) ?? .toggle
            let service = KeyboardShortcutsHotkeyService(
                mode: currentMode,
                onEvent: eventHandler
            )
            self.service = service
            hasConflict = service.hasConflict
        }
        return service?.probeEvents() ?? Self.finishedStream()
    }

    func reset() {
        service?.teardown()
        service = nil
        currentMode = .toggle
        hasConflict = false
    }

    private static func finishedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}
