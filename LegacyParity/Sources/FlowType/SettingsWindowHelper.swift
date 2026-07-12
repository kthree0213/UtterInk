import AppKit

extension Notification.Name {
    /// 打开或已打开的设置窗口应切换到 `userInfo["tab"]`（Int，与 `SettingsView` 的 TabView tag 一致）。
    static let settingsPreferredTabSelect = Notification.Name("settingsPreferredTabSelect")
}

/// 设置 `TabView` 的 tag，与 `SettingsView` 保持一致。
enum SettingsTab {
    static let general = 0
    static let speechModels = 1
    static let shortcuts = 2
    static let outputModes = 3
    static let llmProvider = 4

    private static let pendingKey = "settingsPendingTabIndex"

    /// 在调用 `openSettings()` 前后均可；未打开窗口时写入 UserDefaults，已打开时发通知立即切换。
    static func requestSelectTab(_ tab: Int) {
        guard (general...llmProvider).contains(tab) else { return }
        UserDefaults.standard.set(tab, forKey: pendingKey)
        NotificationCenter.default.post(
            name: .settingsPreferredTabSelect,
            object: nil,
            userInfo: ["tab": tab]
        )
    }

    static func consumePendingTabIfNeeded() -> Int? {
        guard let v = UserDefaults.standard.object(forKey: pendingKey) as? Int,
              (general...llmProvider).contains(v) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return v
    }

    /// 与通知路径配合：已切换 tab 后清除待选标记（避免与 `consumePendingTabIfNeeded` 重复应用）。
    static func discardPendingTab() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    static func isValidTabIndex(_ tab: Int) -> Bool {
        (general...llmProvider).contains(tab)
    }
}

/// 由菜单栏视图注入优先路径；引导窗可能在用户从未点开菜单前弹出，需 `open()` 后备。
enum SettingsOpener {
    static var openFullSettings: (() -> Void)?

    static func open() {
        if let openFullSettings {
            openFullSettings()
        } else {
            SettingsWindowHelper.activateForSettingsPanel()
            _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                SettingsWindowHelper.bringSettingsWindowToFront()
            }
        }
    }
}

/// 菜单栏应用默认 `accessory` 时，设置窗与快捷键录制器难以抢焦点；打开设置时临时切到 `regular` 并置顶。
enum SettingsWindowHelper {
    private static let bringFrontDelay: TimeInterval = 0.12

    static func activateForSettingsPanel() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 打开设置时把设置窗口提到前台一次；保持 `normal` 层级，避免压住系统「隐私与安全性」等普通窗口。
    static func bringSettingsWindowToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + bringFrontDelay) {
            let candidates = NSApp.windows.filter { w in
                w.isVisible
                    && w.styleMask.contains(.titled)
                    && w.canBecomeKey
                    && !w.styleMask.contains(.nonactivatingPanel)
            }
            guard let window = candidates.max(by: { $0.windowNumber < $1.windowNumber }) else { return }
            window.level = .normal
            window.makeKeyAndOrderFront(nil)
            enforceSettingsContentMinSize(assumingWindow: window)
        }
    }

    // MARK: - 设置窗口最小尺寸（避免 Tab 切换后窗口被缩得过窄）

    /// 与 `SettingsView` 里 LLM 双栏 +「通用」长文案匹配；避免标签列与说明被裁切。
    private static let settingsContentMinWidth: CGFloat = 980
    private static let settingsContentMinHeight: CGFloat = 472

    /// SwiftUI `TabView` 切换子页时会按「当前页」固有尺寸重算，系统设置窗口常被缩小；回到 LLM 页仍过窄。
    static func enforceSettingsContentMinSize(assumingWindow window: NSWindow? = nil) {
        let minW = settingsContentMinWidth
        let minH = settingsContentMinHeight
        func apply(to w: NSWindow) {
            guard w.styleMask.contains(.titled) else { return }
            var cmin = w.contentMinSize
            cmin.width = max(cmin.width, minW)
            cmin.height = max(cmin.height, minH)
            w.contentMinSize = cmin
            let cw = w.contentView?.bounds.width ?? w.contentRect(forFrameRect: w.frame).width
            let ch = w.contentView?.bounds.height ?? w.contentRect(forFrameRect: w.frame).height
            if cw < minW || ch < minH {
                w.setContentSize(NSSize(width: max(cw, minW), height: max(ch, minH)))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let w = window {
                apply(to: w)
                return
            }
            if let w = NSApp.keyWindow, w.styleMask.contains(.titled) {
                apply(to: w)
                return
            }
            let titled = NSApp.windows.filter {
                $0.isVisible && $0.styleMask.contains(.titled) && !$0.styleMask.contains(.nonactivatingPanel)
            }
            if let w = titled.max(by: { $0.windowNumber < $1.windowNumber }) {
                apply(to: w)
            }
        }
    }
}
