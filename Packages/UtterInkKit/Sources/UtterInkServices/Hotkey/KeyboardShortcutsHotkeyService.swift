import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import UtterInkCore

protocol HotkeyEventBackend: Sendable {
    func conflictDetected() -> Bool
    func install(
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    )
    func removeHandlers()
}

public final class KeyboardShortcutsHotkeyService: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case startRequested
        case stopRequested
    }

    public static let shortcutName = KeyboardShortcuts.Name("utterink.dictation")

    public let hasConflict: Bool

    private let mode: ShortcutMode
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private let backend: any HotkeyEventBackend
    private let lock = NSLock()
    private var keyIsDown = false
    private var nextToggleEvent = Event.startRequested
    private var tornDown = false
    private var pendingEvents: [Event] = []
    private var deliveryScheduled = false
    private var probeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public convenience init(
        mode: ShortcutMode,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        self.init(
            mode: mode,
            onEvent: onEvent,
            backend: SystemHotkeyEventBackend(name: Self.shortcutName)
        )
    }

    init(
        mode: ShortcutMode,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void,
        backend: any HotkeyEventBackend
    ) {
        self.mode = mode
        self.onEvent = onEvent
        self.backend = backend
        hasConflict = backend.conflictDetected()
        backend.install(
            onKeyDown: { [weak self] in self?.handleKeyDown() },
            onKeyUp: { [weak self] in self?.handleKeyUp() }
        )
    }

    deinit {
        teardown()
    }

    public func probeEvents() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            let shouldFinish = lock.withLock {
                guard !tornDown else { return true }
                probeContinuations[id] = continuation
                return false
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeProbe(id: id)
            }
            if shouldFinish {
                continuation.finish()
            }
        }
    }

    public func teardown() {
        let continuations: [AsyncStream<Void>.Continuation]? = lock.withLock {
            guard !tornDown else { return nil }
            tornDown = true
            keyIsDown = false
            pendingEvents.removeAll()
            deliveryScheduled = false
            let values = Array(probeContinuations.values)
            probeContinuations.removeAll()
            return values
        }
        guard let continuations else { return }

        backend.removeHandlers()
        continuations.forEach { $0.finish() }
    }

    func simulateKeyDown() {
        handleKeyDown()
    }

    func simulateKeyUp() {
        handleKeyUp()
    }

    private func handleKeyDown() {
        let accepted: (
            probes: [AsyncStream<Void>.Continuation],
            shouldScheduleDelivery: Bool
        )? = lock.withLock {
            guard !tornDown, !keyIsDown else { return nil }
            keyIsDown = true

            let event: Event
            switch mode {
            case .holdToTalk:
                event = .startRequested
            case .toggle:
                event = nextToggleEvent
                switch nextToggleEvent {
                case .startRequested:
                    nextToggleEvent = .stopRequested
                case .stopRequested:
                    nextToggleEvent = .startRequested
                }
            }

            pendingEvents.append(event)
            let shouldSchedule = !deliveryScheduled
            deliveryScheduled = true
            return (Array(probeContinuations.values), shouldSchedule)
        }
        guard let accepted else { return }

        accepted.probes.forEach { $0.yield(()) }
        if accepted.shouldScheduleDelivery {
            scheduleEventDelivery()
        }
    }

    private func handleKeyUp() {
        let shouldScheduleDelivery: Bool? = lock.withLock {
            guard !tornDown, keyIsDown else { return nil }
            keyIsDown = false
            guard mode == .holdToTalk else { return false }

            pendingEvents.append(.stopRequested)
            let shouldSchedule = !deliveryScheduled
            deliveryScheduled = true
            return shouldSchedule
        }
        guard shouldScheduleDelivery == true else { return }
        scheduleEventDelivery()
    }

    private func scheduleEventDelivery() {
        Task { @MainActor [weak self] in
            self?.drainEventsOnMainActor()
        }
    }

    @MainActor
    private func drainEventsOnMainActor() {
        while let event = nextPendingEvent() {
            onEvent(event)
        }
    }

    private func nextPendingEvent() -> Event? {
        lock.withLock {
            guard !tornDown, !pendingEvents.isEmpty else {
                deliveryScheduled = false
                return nil
            }
            return pendingEvents.removeFirst()
        }
    }

    private func removeProbe(id: UUID) {
        lock.withLock {
            probeContinuations[id] = nil
        }
    }
}

private struct SystemHotkeyEventBackend: HotkeyEventBackend {
    private let name: KeyboardShortcuts.Name

    init(name: KeyboardShortcuts.Name) {
        self.name = name
    }

    func conflictDetected() -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            return false
        }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode),
            UInt32(shortcut.carbonModifiers),
            EventHotKeyID(signature: 0x5554_494B, id: 1),
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        return status != noErr
    }

    func install(
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) {
        KeyboardShortcuts.onKeyDown(for: name, action: onKeyDown)
        KeyboardShortcuts.onKeyUp(for: name, action: onKeyUp)
    }

    func removeHandlers() {
        KeyboardShortcuts.removeHandler(for: name)
    }
}
