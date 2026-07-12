import ApplicationServices
import Cocoa
import Foundation

public class TextInjector {
    /// 避免每次结束录音都调用 `AXIsProcessTrustedWithOptions(prompt: true)`，否则会反复弹出系统「辅助功能」对话框。
    private static var didShowSystemAccessibilityPrompt = false

    public init() {}

    /// 供界面展示：系统「辅助功能」列表按应用路径区分条目，用户可与下方路径核对。
    public static var currentExecutablePathForDiagnostics: String {
        guard let p = CommandLine.arguments.first, !p.isEmpty else {
            return "（无法取得路径）"
        }
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    public static func isAccessibilityTrustedForCurrentProcess() -> Bool {
        AXIsProcessTrusted()
    }

    public func isAccessibilityTrusted() -> Bool {
        Self.isAccessibilityTrustedForCurrentProcess()
    }

    /// 若已信任则返回 `true`；否则在整个进程生命周期内最多触发一次系统授权对话框，然后返回当前是否已信任。
    public func ensureTrustedForInjection() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !Self.didShowSystemAccessibilityPrompt {
            Self.didShowSystemAccessibilityPrompt = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public static func openSystemAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    public static func openSystemMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    public func inject(text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }
        
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
