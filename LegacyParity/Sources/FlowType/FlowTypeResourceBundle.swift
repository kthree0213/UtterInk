import AppKit
import Foundation

/// SPM 资源在 `.app` 内位于 `Contents/MacOS/FlowType_FlowType.bundle`；`Bundle.module` 在部分安装环境下解析不稳，故对菜单栏等资源做显式回退。
enum FlowTypeResourceBundle {
    static var resolved: Bundle {
        let main = Bundle.main
        if let exec = main.executableURL {
            let url = exec.deletingLastPathComponent().appendingPathComponent("FlowType_FlowType.bundle", isDirectory: true)
            if let b = Bundle(url: url) {
                return b
            }
        }
        return Bundle.module
    }

    /// 优先使用导出的独立 PNG（菜单栏）；失败再交给调用方用 Asset 名尝试。
    static func menuBarStatusImage() -> NSImage? {
        let b = resolved
        for name in ["MenuBarIcon_statusbar@2x", "MenuBarIcon_statusbar"] {
            if let url = b.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}
