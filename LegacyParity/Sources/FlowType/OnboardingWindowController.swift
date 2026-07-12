import AppKit
import SwiftUI

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: OnboardingPreferences.dismissedKey)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 首次引导：独立窗口，避免依赖 `MenuBarExtra` 的 `openWindow`。
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private let windowDelegate = OnboardingWindowDelegate()

    private init() {}

    func presentIfNeeded(appState: AppState) {
        guard !UserDefaults.standard.bool(forKey: OnboardingPreferences.dismissedKey) else { return }
        present(appState: appState)
    }

    func present(appState: AppState) {
        SettingsWindowHelper.activateForSettingsPanel()

        let root = OnboardingView(appState: appState) { [weak self] in
            UserDefaults.standard.set(true, forKey: OnboardingPreferences.dismissedKey)
            self?.closeWindow()
        }

        if window == nil {
            let hosting = NSHostingView(rootView: root)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = OnboardingLocalization(
                useChinese: AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
            ).windowTitle
            w.contentView = hosting
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = windowDelegate
            window = w
        } else {
            window?.contentView = NSHostingView(rootView: root)
            window?.title = OnboardingLocalization(
                useChinese: AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
            ).windowTitle
        }

        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.close()
    }
}
