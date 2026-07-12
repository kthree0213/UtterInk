import Cocoa
import SwiftUI

class FloatingWindowController {
    static let shared = FloatingWindowController()
    private var panel: NSPanel?

    func show(with state: AppState) {
        if panel == nil {
            let hostView = NSHostingView(rootView: DynamicIslandView(appState: state))

            panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
                            backing: .buffered, defer: false)
            panel?.isFloatingPanel = true
            panel?.level = .floating
            panel?.backgroundColor = .clear
            panel?.isOpaque = false
            panel?.hasShadow = true
            panel?.contentView = hostView
            // 若为 true，无边框面板会把点击交给「拖窗口」，常与胶囊里的 Button 冲突（第二次点击无响应）。
            panel?.isMovableByWindowBackground = false
            
            panel?.setFrameAutosaveName("FlowTypeIslandPosition")
            
            if panel?.frameAutosaveName == nil || UserDefaults.standard.string(forKey: "NSWindow Frame FlowTypeIslandPosition") == nil {
                if let screen = NSScreen.main {
                    let screenRect = screen.visibleFrame
                    let x = screenRect.midX - 200
                    let y = screenRect.maxY - 60
                    panel?.setFrameOrigin(NSPoint(x: x, y: y))
                }
            }
        }
        panel?.orderFront(nil)
    }
    
    func hide() {
        panel?.orderOut(nil)
    }
}
