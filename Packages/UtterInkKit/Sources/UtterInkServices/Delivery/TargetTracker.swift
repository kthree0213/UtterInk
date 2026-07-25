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
        primeExternalFocusTracking()
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
        let previous = lastEligibleExternal
        switch platform.currentFocus() {
        case .ownApplication:
            return
        case let .target(current):
            lastEligibleExternal = current
            // Several custom editors emit focused-element notifications even
            // though the actual window and input target did not change. Do
            // not invalidate an active dictation for those no-op events.
            if let previous, platform.sameTarget(previous, current) {
                return
            }
        case .none, .unavailable:
            lastEligibleExternal = nil
        }

        focusEpoch &+= 1
        for id in records.keys {
            records[id]?.invalidated = true
        }
    }

    private func primeExternalFocusTracking() {
        guard case let .target(current) = platform.currentFocus() else { return }
        lastEligibleExternal = current
    }
}

@MainActor
private final class AppKitTargetSystemPlatform: TargetSystemPlatform {
    private struct ResolvedFocus {
        let element: AXUIElement
        let scope: AppKitFocusScope
    }

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
        elementPID(applicationElement) == pid,
        elementPID(window) == pid
        else {
            return .none
        }

        let focusedResult = copiedElementResult(
            from: applicationElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        )
        let resolved: ResolvedFocus
        if focusedResult.error == .success,
           let focused = focusedResult.element,
           elementPID(focused) == pid,
           let focus = resolvedFocus(
               focused: focused,
               window: window,
               pid: pid
           ) {
            resolved = focus
        } else if let fallback = windowScopedFocus(in: window, pid: pid) {
            resolved = fallback
        } else {
            return .none
        }

        configureAXObserver(
            pid: pid,
            application: applicationElement,
            window: window,
            focused: resolved.element
        )
        return .target(
            TargetFocusReference(
                pid: pid,
                opaqueIdentity: AppKitFocusIdentity(
                    application: application,
                    applicationElement: applicationElement,
                    windowElement: window,
                    focusedElement: resolved.element,
                    scope: resolved.scope
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
              sameFocusScope(capturedIdentity.scope, liveIdentity.scope, live: liveIdentity)
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

    private func copiedElementResult(
        from element: AXUIElement,
        attribute: CFString
    ) -> (error: AXError, element: AXUIElement?) {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard error == .success,
              let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else {
            return (error, nil)
        }
        return (error, (raw as! AXUIElement))
    }

    private func copiedElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        copiedElementResult(from: element, attribute: attribute).element
    }

    private func copiedElements(from element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let values = raw as? [AXUIElement]
        else {
            return []
        }
        return values
    }

    private func elementPID(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func isExactlyEditable(_ element: AXUIElement) -> Bool {
        guard isEnabledOrUnknown(element) else { return false }
        return isAttributeSettable(kAXValueAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
            || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }

    private func isEnabledOrUnknown(_ element: AXUIElement) -> Bool {
        var rawEnabled: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &rawEnabled
        )
        if error == .success, let enabled = rawEnabled as? Bool {
            return enabled
        }
        // Some Electron and custom AppKit controls omit AXEnabled while still
        // exposing a stable focused text target. Reject explicit false, but do
        // not reject an otherwise usable target solely for a missing value.
        return error == .noValue || error == .attributeUnsupported
    }

    private func resolvedFocus(
        focused: AXUIElement,
        window: AXUIElement,
        pid: pid_t
    ) -> ResolvedFocus? {
        if isExactlyEditable(focused) {
            return ResolvedFocus(element: focused, scope: .exact)
        }
        if let descendant = singleEditableDescendant(in: focused, pid: pid) {
            return ResolvedFocus(element: descendant, scope: .exact)
        }
        if let role = focusProxyRole(focused) {
            return ResolvedFocus(
                element: focused,
                scope: .focusedProxy(role: role)
            )
        }
        return windowScopedFocus(in: window, pid: pid)
    }

    private func singleEditableDescendant(
        in root: AXUIElement,
        pid: pid_t
    ) -> AXUIElement? {
        var queue = copiedElements(
            from: root,
            attribute: kAXChildrenAttribute as CFString
        ).map { (element: $0, depth: 1) }
        var index = 0
        var match: AXUIElement?

        while index < queue.count, index < 96 {
            let item = queue[index]
            index += 1
            guard item.depth <= 6, elementPID(item.element) == pid else { continue }

            if isExactlyEditable(item.element) {
                // More than one editable descendant is ambiguous and must not
                // be used for automatic delivery.
                guard match == nil else { return nil }
                match = item.element
            }
            if item.depth < 6 {
                queue.append(contentsOf: copiedElements(
                    from: item.element,
                    attribute: kAXChildrenAttribute as CFString
                ).map { (element: $0, depth: item.depth + 1) })
            }
        }
        return match
    }

    private func focusProxyRole(_ element: AXUIElement) -> String? {
        guard isEnabledOrUnknown(element),
              let role = copiedString(
                  from: element,
                  attribute: kAXRoleAttribute as CFString
              ),
              Self.supportedFocusProxyRoles.contains(role),
              elementFrame(element) != nil else {
            return nil
        }
        return role
    }

    private func copiedString(from element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    private func windowScopedFocus(in window: AXUIElement, pid: pid_t) -> ResolvedFocus? {
        guard let windowFrame = elementFrame(window) else { return nil }

        var parent = window
        var selected: ResolvedFocus?
        for _ in 0..<32 {
            let candidates = copiedElements(
                from: parent,
                attribute: kAXChildrenAttribute as CFString
            ).compactMap { candidate -> ResolvedFocus? in
                guard elementPID(candidate) == pid,
                      isWindowScopedEditableProxy(candidate),
                      let frame = elementFrame(candidate),
                      framesMatch(frame, windowFrame),
                      let selection = selectionFingerprint(candidate)
                else {
                    return nil
                }
                return ResolvedFocus(
                    element: candidate,
                    scope: .windowScoped(selection: selection)
                )
            }

            // More than one editable proxy would make the target ambiguous.
            guard candidates.count <= 1 else { return nil }
            guard let candidate = candidates.first else { break }
            selected = candidate
            parent = candidate.element
        }
        return selected
    }

    private func isWindowScopedEditableProxy(_ element: AXUIElement) -> Bool {
        var rawRole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &rawRole
        ) == .success,
        (rawRole as? String) == (kAXGroupRole as String),
        isEnabledOrUnknown(element),
        isAttributeSettable(kAXValueAttribute as CFString, on: element),
        isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element),
        isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
        else {
            return false
        }

        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success,
              (rawActions as? [String])?.isEmpty == true
        else {
            return false
        }
        return true
    }

    private func selectionFingerprint(_ element: AXUIElement) -> AppKitSelectionFingerprint? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        ) == .success,
        let raw,
        CFGetTypeID(raw) == AXValueGetTypeID(),
        AXValueGetType(raw as! AXValue) == .cfRange
        else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return AppKitSelectionFingerprint(location: range.location, length: range.length)
    }

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &rawSize
        ) == .success,
        let rawPosition,
        let rawSize,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID(),
        AXValueGetType(rawPosition as! AXValue) == .cgPoint,
        AXValueGetType(rawSize as! AXValue) == .cgSize
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func sameFocusScope(
        _ captured: AppKitFocusScope,
        _ liveScope: AppKitFocusScope,
        live: AppKitFocusIdentity
    ) -> Bool {
        switch (captured, liveScope) {
        case (.exact, .exact):
            return isExactlyEditable(live.focusedElement)
        case let (.focusedProxy(capturedRole), .focusedProxy(liveRole)):
            return capturedRole == liveRole
                && focusProxyRole(live.focusedElement) == liveRole
        case let (.windowScoped(capturedSelection), .windowScoped(liveSelection)):
            return capturedSelection == liveSelection
                && isWindowScopedEditableProxy(live.focusedElement)
                && selectionFingerprint(live.focusedElement) == liveSelection
        case (.exact, .focusedProxy), (.exact, .windowScoped),
             (.focusedProxy, .exact), (.focusedProxy, .windowScoped),
             (.windowScoped, .exact), (.windowScoped, .focusedProxy):
            return false
        }
    }

    private static let supportedFocusProxyRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXGroup",
        "AXWebArea",
        "AXScrollArea",
    ]

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
    let scope: AppKitFocusScope

    init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        windowElement: AXUIElement,
        focusedElement: AXUIElement,
        scope: AppKitFocusScope
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.windowElement = windowElement
        self.focusedElement = focusedElement
        self.scope = scope
    }
}

private struct AppKitSelectionFingerprint: Equatable {
    let location: Int
    let length: Int
}

private enum AppKitFocusScope {
    case exact
    case focusedProxy(role: String)
    case windowScoped(selection: AppKitSelectionFingerprint)
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
