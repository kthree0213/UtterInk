import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import UtterInkCore

@MainActor
protocol TargetSystemPlatform: AnyObject, Sendable {
    func installChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void)
    func canPostProcessAddressedEvents() -> Bool
    func currentFocus() -> TargetFocusLookup
    func sameTarget(_ captured: TargetFocusReference, _ live: TargetFocusReference) -> Bool
    func postCommandV(to target: TargetFocusReference, token: EffectToken) -> Bool
    func tearDown()
}

@MainActor
enum TargetFocusLookup {
    case target(TargetFocusReference)
    case ownApplication
    case none
    case unavailable
}

@MainActor
final class TargetFocusReference {
    let pid: pid_t
    let opaqueIdentity: AnyObject

    init(
        pid: pid_t,
        opaqueIdentity: AnyObject
    ) {
        self.pid = pid
        self.opaqueIdentity = opaqueIdentity
    }
}

@MainActor
public final class TargetTracker: TargetSnapshotService, TargetValidating, @unchecked Sendable {
    private struct CapturedTarget {
        let reference: TargetFocusReference
        let epoch: UInt64
        var invalidated: Bool
    }

    private let clock: any AppClock
    private let platform: any TargetSystemPlatform
    private var focusEpoch: UInt64 = 0
    private var records: [DeliveryTargetID: CapturedTarget] = [:]
    private var lastEligibleExternal: TargetFocusReference?

    public convenience init(clock: any AppClock) {
        self.init(clock: clock, platform: AppKitTargetSystemPlatform())
    }

    init(clock: any AppClock, platform: any TargetSystemPlatform) {
        self.clock = clock
        self.platform = platform
        platform.installChangeHandler { [weak self] in
            self?.handleObservedFocusChange()
        }
    }

    deinit {
        let retainedPlatform = platform
        Task { @MainActor in retainedPlatform.tearDown() }
    }

    public func snapshotTarget() async -> DeliveryTarget {
        _ = clock.now
        guard platform.canPostProcessAddressedEvents() else { return .copyOnly }
        let reference: TargetFocusReference
        switch platform.currentFocus() {
        case let .target(current):
            reference = current
            lastEligibleExternal = current
        case .ownApplication:
            guard let retained = lastEligibleExternal else { return .copyOnly }
            reference = retained
        case .none, .unavailable:
            return .copyOnly
        }

        let id = DeliveryTargetID()
        records[id] = CapturedTarget(
            reference: reference,
            epoch: focusEpoch,
            invalidated: false
        )
        return .external(id)
    }

    func validate(targetID: DeliveryTargetID, token: EffectToken) async -> TargetValidation {
        guard !Task.isCancelled else { return .changed }
        return validateSynchronously(targetID: targetID)
    }

    func revalidateAndDispatch(
        targetID: DeliveryTargetID,
        token: EffectToken
    ) async -> TargetDispatch {
        guard !Task.isCancelled else { return .changed }
        switch validateSynchronously(targetID: targetID) {
        case .unavailable:
            return .unavailable
        case .changed:
            return .changed
        case .valid:
            break
        }
        guard let captured = records[targetID], !captured.invalidated else {
            return .unavailable
        }
        guard !Task.isCancelled else { return .changed }
        return platform.postCommandV(to: captured.reference, token: token) ? .dispatched : .failed
    }

    private func validateSynchronously(targetID: DeliveryTargetID) -> TargetValidation {
        guard var captured = records[targetID] else { return .unavailable }
        guard !captured.invalidated else { return .changed }
        guard captured.epoch == focusEpoch else {
            captured.invalidated = true
            records[targetID] = captured
            return .changed
        }

        switch platform.currentFocus() {
        case .unavailable:
            return .unavailable
        case .ownApplication, .none:
            captured.invalidated = true
            records[targetID] = captured
            return .changed
        case let .target(live):
            guard platform.sameTarget(captured.reference, live) else {
                captured.invalidated = true
                records[targetID] = captured
                return .changed
            }
            return .valid
        }
    }

    private func handleObservedFocusChange() {
        switch platform.currentFocus() {
        case .ownApplication:
            return
        case let .target(current):
            lastEligibleExternal = current
        case .none, .unavailable:
            lastEligibleExternal = nil
        }

        focusEpoch &+= 1
        for id in records.keys {
            records[id]?.invalidated = true
        }
    }
}

@MainActor
private final class AppKitTargetSystemPlatform: TargetSystemPlatform {
    private var changeHandler: (@MainActor @Sendable () -> Void)?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?

    func installChangeHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        changeHandler = handler
        let center = NSWorkspace.shared.notificationCenter
        let activation = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self else { return }
                if application?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    return
                }
                self.changeHandler?()
            }
        }
        let termination = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.changeHandler?() }
        }
        workspaceTokens = [activation, termination]
    }

    func canPostProcessAddressedEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    func currentFocus() -> TargetFocusLookup {
        guard AXIsProcessTrusted() else { return .unavailable }
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated
        else {
            return .none
        }
        let pid = application.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return .ownApplication
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        guard let window = copiedElement(
            from: applicationElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ),
        let focused = copiedElement(
            from: applicationElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ),
        elementPID(applicationElement) == pid,
        elementPID(window) == pid,
        elementPID(focused) == pid,
        isExactlyEditable(focused)
        else {
            return .none
        }

        configureAXObserver(
            pid: pid,
            application: applicationElement,
            window: window,
            focused: focused
        )
        return .target(
            TargetFocusReference(
                pid: pid,
                opaqueIdentity: AppKitFocusIdentity(
                    application: application,
                    applicationElement: applicationElement,
                    windowElement: window,
                    focusedElement: focused
                )
            )
        )
    }

    func sameTarget(_ captured: TargetFocusReference, _ live: TargetFocusReference) -> Bool {
        guard let capturedIdentity = captured.opaqueIdentity as? AppKitFocusIdentity,
              let liveIdentity = live.opaqueIdentity as? AppKitFocusIdentity,
              !capturedIdentity.application.isTerminated,
              capturedIdentity.application.isEqual(liveIdentity.application),
              captured.pid == live.pid,
              elementPID(capturedIdentity.applicationElement) == captured.pid,
              elementPID(capturedIdentity.windowElement) == captured.pid,
              elementPID(capturedIdentity.focusedElement) == captured.pid,
              CFEqual(capturedIdentity.windowElement, liveIdentity.windowElement),
              CFEqual(capturedIdentity.focusedElement, liveIdentity.focusedElement),
              isExactlyEditable(liveIdentity.focusedElement)
        else {
            return false
        }
        return true
    }

    func postCommandV(to target: TargetFocusReference, token: EffectToken) -> Bool {
        guard let identity = target.opaqueIdentity as? AppKitFocusIdentity else {
            return false
        }
        guard !Task.isCancelled,
              !identity.application.isTerminated,
              identity.application.processIdentifier == target.pid,
              canPostProcessAddressedEvents(),
              let down = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let up = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              )
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard !Task.isCancelled else { return false }
        down.postToPid(target.pid)
        up.postToPid(target.pid)
        return true
    }

    func tearDown() {
        tearDownAXObserver()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens {
            center.removeObserver(token)
        }
        workspaceTokens.removeAll()
        changeHandler = nil
    }

    private func copiedElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (raw as! AXUIElement)
    }

    private func elementPID(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func isExactlyEditable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success,
        settable.boolValue
        else {
            return false
        }

        var rawEnabled: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &rawEnabled
        ) == .success,
        let enabled = rawEnabled as? Bool
        else {
            return false
        }
        return enabled
    }

    private func configureAXObserver(
        pid: pid_t,
        application: AXUIElement,
        window: AXUIElement,
        focused: AXUIElement
    ) {
        tearDownAXObserver()
        var created: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, utterInkAXObserverCallback, &created) == .success,
              let created
        else {
            return
        }
        axObserver = created
        observedApplicationElement = application
        observedWindowElement = window
        observedFocusedElement = focused

        _ = AXObserverAddNotification(
            created,
            application,
            kAXFocusedWindowChangedNotification as CFString,
            context
        )
        _ = AXObserverAddNotification(
            created,
            application,
            kAXFocusedUIElementChangedNotification as CFString,
            context
        )
        _ = AXObserverAddNotification(
            created,
            window,
            kAXUIElementDestroyedNotification as CFString,
            context
        )
        _ = AXObserverAddNotification(
            created,
            focused,
            kAXUIElementDestroyedNotification as CFString,
            context
        )
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .defaultMode
        )
    }

    private func tearDownAXObserver() {
        guard let observer = axObserver else { return }
        if let application = observedApplicationElement {
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedWindowChangedNotification as CFString
            )
            AXObserverRemoveNotification(
                observer,
                application,
                kAXFocusedUIElementChangedNotification as CFString
            )
        }
        if let window = observedWindowElement {
            AXObserverRemoveNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        if let focused = observedFocusedElement {
            AXObserverRemoveNotification(
                observer,
                focused,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        axObserver = nil
        observedApplicationElement = nil
        observedWindowElement = nil
        observedFocusedElement = nil
    }

    fileprivate func receivedAXNotification() {
        changeHandler?()
    }
}

@MainActor
private final class AppKitFocusIdentity {
    let application: NSRunningApplication
    let applicationElement: AXUIElement
    let windowElement: AXUIElement
    let focusedElement: AXUIElement

    init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        windowElement: AXUIElement,
        focusedElement: AXUIElement
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.windowElement = windowElement
        self.focusedElement = focusedElement
    }
}

private func utterInkAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let owner = Unmanaged<AppKitTargetSystemPlatform>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in owner.receivedAXNotification() }
}
