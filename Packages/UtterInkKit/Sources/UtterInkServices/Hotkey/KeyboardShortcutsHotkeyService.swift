import AppKit
import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts
import SwiftUI
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

    public static var hasConfiguredShortcut: Bool {
        KeyboardShortcuts.getShortcut(for: shortcutName) != nil
    }

    public static func resetShortcut() {
        KeyboardShortcuts.reset(shortcutName)
    }

    public let hasConflict: Bool

    private let mode: ShortcutMode
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private let backend: any HotkeyEventBackend
    private let lock = NSLock()
    private var keyIsDown = false
    private var currentPressIsSuppressed = false
    private var nextToggleEvent = Event.startRequested
    private var tornDown = false
    private var pendingEvents: [Event] = []
    private var deliveryScheduled = false
    private struct ProbeSubscription {
        let continuation: AsyncStream<Void>.Continuation
        let suppressesCommand: Bool
    }

    private var probeSubscriptions: [UUID: ProbeSubscription] = [:]

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

    public func probeEvents(
        suppressingCommand: Bool = false
    ) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            let shouldFinish = lock.withLock {
                guard !tornDown else { return true }
                probeSubscriptions[id] = ProbeSubscription(
                    continuation: continuation,
                    suppressesCommand: suppressingCommand
                )
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
            currentPressIsSuppressed = false
            pendingEvents.removeAll()
            deliveryScheduled = false
            let values = probeSubscriptions.values.map(\.continuation)
            probeSubscriptions.removeAll()
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
            oneShotProbes: [AsyncStream<Void>.Continuation],
            shouldScheduleDelivery: Bool
        )? = lock.withLock {
            guard !tornDown, !keyIsDown else { return nil }
            keyIsDown = true

            let subscriptions = Array(probeSubscriptions)
            let suppressesCommand = subscriptions.contains {
                $0.value.suppressesCommand
            }
            currentPressIsSuppressed = suppressesCommand
            let oneShotIDs = subscriptions.compactMap { entry in
                entry.value.suppressesCommand ? entry.key : nil
            }
            let oneShotProbes = oneShotIDs.compactMap {
                probeSubscriptions.removeValue(forKey: $0)?.continuation
            }

            guard !suppressesCommand else {
                return (
                    subscriptions.map { $0.value.continuation },
                    oneShotProbes,
                    false
                )
            }

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
            return (
                subscriptions.map { $0.value.continuation },
                oneShotProbes,
                shouldSchedule
            )
        }
        guard let accepted else { return }

        accepted.probes.forEach { $0.yield(()) }
        accepted.oneShotProbes.forEach { $0.finish() }
        if accepted.shouldScheduleDelivery {
            scheduleEventDelivery()
        }
    }

    private func handleKeyUp() {
        let shouldScheduleDelivery: Bool? = lock.withLock {
            guard !tornDown, keyIsDown else { return nil }
            keyIsDown = false
            let wasSuppressed = currentPressIsSuppressed
            currentPressIsSuppressed = false
            guard !wasSuppressed else { return false }
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
            probeSubscriptions[id] = nil
        }
    }
}

public struct DictationShortcutRecorder: View {
    private let onChange: (Bool) -> Void
    private let accessibleName: String

    public init(
        accessibleName: String = "Recorder Shortcut",
        onChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.accessibleName = accessibleName
        self.onChange = onChange
    }

    public var body: some View {
        AccessibleShortcutRecorder(
            accessibleName: accessibleName,
            onChange: onChange
        )
    }
}

private struct AccessibleShortcutRecorder: NSViewRepresentable {
    let accessibleName: String
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> AccessibleShortcutRecorderControl {
        let recorder = AccessibleShortcutRecorderControl()
        recorder.accessibleName = accessibleName
        recorder.onChange = onChange
        recorder.refreshPresentation()
        return recorder
    }

    func updateNSView(_ recorder: AccessibleShortcutRecorderControl, context: Context) {
        recorder.accessibleName = accessibleName
        recorder.onChange = onChange
        recorder.refreshPresentation()
    }

    static func dismantleNSView(
        _ recorder: AccessibleShortcutRecorderControl,
        coordinator: ()
    ) {
        recorder.cancelRecording()
    }
}

@MainActor
private final class AccessibleShortcutRecorderControl: NSButton {
    var accessibleName = "Recorder Shortcut" {
        didSet { refreshAccessibility() }
    }
    var onChange: (Bool) -> Void = { _ in }

    private var isRecording = false
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?

    override var canBecomeKeyView: Bool { true }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, 130)
        return size
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshPresentation()
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 130, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            cancelRecording()
        }
        return didResign
    }

    @objc
    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        KeyboardShortcuts.disable(KeyboardShortcutsHotkeyService.shortcutName)
        title = "Press Shortcut"
        refreshAccessibility()
        window?.makeFirstResponder(self)
        observeRecordingContext()
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordingEvent(event) ?? event
        }
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.handleRecordingMouseEvent(event) ?? event
        }
    }

    func cancelRecording() {
        guard isRecording || keyEventMonitor != nil || mouseEventMonitor != nil else { return }
        stopRecording()
    }

    func refreshPresentation() {
        guard !isRecording else { return }
        if let shortcut = KeyboardShortcuts.getShortcut(
            for: KeyboardShortcutsHotkeyService.shortcutName
        ) {
            title = shortcut.description
        } else {
            title = "Record Shortcut"
        }
        refreshAccessibility()
        invalidateIntrinsicContentSize()
    }

    private func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording, !event.isARepeat else { return nil }

        if event.keyCode == UInt16(kVK_Tab),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            stopRecording()
            return event
        }

        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return nil
        }

        if event.keyCode == UInt16(kVK_Delete)
            || event.keyCode == UInt16(kVK_ForwardDelete) {
            stopRecording()
            KeyboardShortcuts.setShortcut(
                nil,
                for: KeyboardShortcutsHotkeyService.shortcutName
            )
            refreshPresentation()
            onChange(false)
            return nil
        }

        guard hasRequiredModifier(event) else {
            NSSound.beep()
            return nil
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return nil
        }

        let conflict = conflict(for: shortcut)
        stopRecording()
        if let conflict {
            switch conflict {
            case let .menuItem(message):
                showMenuShortcutConflict(message)
                return nil
            case let .system(message):
                guard confirmUsingConflictingShortcut(message) else { return nil }
            }
        }

        KeyboardShortcuts.setShortcut(
            shortcut,
            for: KeyboardShortcutsHotkeyService.shortcutName
        )
        refreshPresentation()
        onChange(true)
        return nil
    }

    private func stopRecording() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
        }
        keyEventMonitor = nil
        mouseEventMonitor = nil
        stopObservingRecordingContext()
        isRecording = false
        KeyboardShortcuts.enable(KeyboardShortcutsHotkeyService.shortcutName)
        refreshPresentation()
    }

    private func handleRecordingMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.window === window {
            let localPoint = convert(event.locationInWindow, from: nil)
            if bounds.contains(localPoint) {
                stopRecording()
                return nil
            }
        }

        stopRecording()
        return event
    }

    private func observeRecordingContext() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingContextDidDeactivate(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingContextDidDeactivate(_:)),
            name: NSApplication.didResignActiveNotification,
            object: NSApp
        )
    }

    private func stopObservingRecordingContext() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc
    private func recordingContextDidDeactivate(_: Notification) {
        cancelRecording()
    }

    private func refreshAccessibility() {
        setAccessibilityLabel(accessibleName)
        if isRecording {
            setAccessibilityValue("Recording. Press a shortcut, Escape to cancel, or Delete to clear.")
            setAccessibilityHelp("Press a shortcut. Tab moves to the next control without changing it.")
        } else {
            let value = KeyboardShortcuts.getShortcut(
                for: KeyboardShortcutsHotkeyService.shortcutName
            )?.description ?? "Not set"
            setAccessibilityValue(value)
            setAccessibilityHelp("Press to record a new dictation shortcut.")
        }
    }

    private func hasRequiredModifier(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return true
        }
        return Self.functionKeyCodes.contains(Int(event.keyCode))
    }

    private func conflict(
        for shortcut: KeyboardShortcuts.Shortcut
    ) -> ShortcutConflict? {
        if let item = menuItem(using: shortcut, in: NSApp.mainMenu) {
            return .menuItem(
                "This shortcut is already used by the \(item.title) menu item. Choose a different shortcut."
            )
        }

        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.carbonKeyCode),
            UInt32(shortcut.carbonModifiers),
            EventHotKeyID(signature: 0x5554_4952, id: 1),
            GetEventDispatcherTarget(),
            0,
            &hotKey
        )
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        guard status == noErr else {
            return .system("This shortcut is already used by macOS or another app.")
        }
        return nil
    }

    private func menuItem(
        using shortcut: KeyboardShortcuts.Shortcut,
        in menu: NSMenu?
    ) -> NSMenuItem? {
        guard let menu,
              let expectedKey = shortcut.nsMenuItemKeyEquivalent
        else { return nil }

        for item in menu.items {
            var key = item.keyEquivalent
            var modifiers = item.keyEquivalentModifierMask
            if shortcut.modifiers.contains(.shift), key.lowercased() != key {
                key = key.lowercased()
                modifiers.insert(.shift)
            }
            if key == expectedKey, modifiers == shortcut.modifiers {
                return item
            }
            if let match = menuItem(using: shortcut, in: item.submenu) {
                return match
            }
        }
        return nil
    }

    private func confirmUsingConflictingShortcut(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keyboard Shortcut Is Already in Use"
        alert.informativeText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func showMenuShortcutConflict(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Keyboard Shortcut Conflicts with an App Menu"
        alert.informativeText = message
        alert.addButton(withTitle: "Choose Another Shortcut")
        alert.runModal()
    }

    private enum ShortcutConflict {
        case menuItem(String)
        case system(String)
    }

    private static let functionKeyCodes: Set<Int> = [
        Int(kVK_F1), Int(kVK_F2), Int(kVK_F3), Int(kVK_F4), Int(kVK_F5),
        Int(kVK_F6), Int(kVK_F7), Int(kVK_F8), Int(kVK_F9), Int(kVK_F10),
        Int(kVK_F11), Int(kVK_F12), Int(kVK_F13), Int(kVK_F14), Int(kVK_F15),
        Int(kVK_F16), Int(kVK_F17), Int(kVK_F18), Int(kVK_F19), Int(kVK_F20),
    ]

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
        }
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
        }
        NotificationCenter.default.removeObserver(self)
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
