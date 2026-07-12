import AppKit
import SwiftUI

@MainActor
class AppState: ObservableObject {
    @Published var isAppEnabled = true {
        didSet {
            if isAppEnabled {
                FloatingWindowController.shared.show(with: self)
            } else {
                FloatingWindowController.shared.hide()
            }
        }
    }
    @Published var isRecording = false
    /// 录音时麦克风输入电平（0…1，已平滑），供灵动岛音量动效；非录音时应为 0。
    @Published var microphoneInputLevel: CGFloat = 0
    /// 当前这一段录音开始的时间；用于灵动岛计时器。
    @Published var recordingStartedAt: Date?
    @Published var isProcessing = false
    @Published var availableModels: [String] = []
    /// 灵动岛 / 状态区展示的提示文案（历史命名；不仅限于辅助功能）。
    @Published var accessibilityNotice: String?
    /// 与 `accessibilityNotice` 配套：决定主操作按钮打开哪类系统设置。
    @Published var userNoticeAction: UserNoticeAction = .none

    enum UserNoticeAction: Equatable {
        case accessibility
        case microphone
        case none
    }
    /// `nil` = 空闲；下载阶段为 0…1，进入 Core ML 加载前会置为 1
    @Published var whisperModelLoadProgress: Double?
    /// 下载阶段由 `Progress` 估算的速率（字节/秒），无则 `nil`。
    @Published var whisperModelLoadThroughputBytesPerSecond: Double?
    @Published var whisperModelLoadPhase: WhisperModelLoadPhase?
    /// 正在下载/加载中的 Whisper 变体 id（与 `whisperKitModelId` 一致时表示当前选项在忙）。
    @Published var whisperTargetLoadVariantId: String?

    var coordinator: FlowCoordinator?

    enum WhisperModelLoadPhase: String, Equatable {
        case downloading
        case loading
    }

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.startup()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessibilityNoticeAfterReturningFromSettings()
            }
        }
    }

    /// 从系统设置返回后 AX 信任状态可能已更新，仅清除「辅助功能」类提示，避免误清麦克风/网络等其它提示。
    private func refreshAccessibilityNoticeAfterReturningFromSettings() {
        guard userNoticeAction == .accessibility else { return }
        guard TextInjector.isAccessibilityTrustedForCurrentProcess() else { return }
        clearUserNotice()
    }

    func setUserNotice(_ message: String, action: UserNoticeAction) {
        accessibilityNotice = message
        userNoticeAction = action
    }

    func clearUserNotice() {
        accessibilityNotice = nil
        userNoticeAction = .none
    }

    private func startup() {
        applyDockIconFromBundle()
        SpeechTranscriptionSettings.migrateUserDefaultsIfNeeded()
        FloatingWindowController.shared.show(with: self)

        let newCoordinator = FlowCoordinator(appState: self)
        newCoordinator.start()
        self.coordinator = newCoordinator

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            OnboardingWindowController.shared.presentIfNeeded(appState: self)
        }
    }

    func reloadLLMFromUserDefaults() {
        coordinator?.reloadLLMConfigurationFromDefaults()
    }

    /// 纯 SPM 构建多为裸可执行文件，无 `.app` 内 `icns`；用资源包内 PNG 设置 Dock 图标（与 Finder 里 .app 图标无关）。
    private func applyDockIconFromBundle() {
        guard let url = Bundle.module.url(forResource: "AppDockIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

/// 菜单栏：安装版以独立 PNG + `FlowType_FlowType.bundle` 路径加载，避免仅依赖 Asset 时 `Bundle.module` 解析失败出现空白圆块。
private struct MenuBarExtraIconLabel: View {
    var body: some View {
        if let img = FlowTypeResourceBundle.menuBarStatusImage() {
            Image(nsImage: img)
                .renderingMode(.template)
        } else {
            Image("MenuBarIcon", bundle: FlowTypeResourceBundle.resolved)
                .renderingMode(.template)
        }
    }
}

@main
struct FlowTypeApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        /// 图标：`MenuBarIcon` 为 Template（黑形透明底），与系统菜单栏单色图标一致；见 Resources/README.txt。
        MenuBarExtra {
            MenuBarRootView(appState: appState)
        } label: {
            MenuBarExtraIconLabel()
                .accessibilityLabel("FlowType")
        }

        Settings {
            SettingsView(appState: appState)
        }
    }
}
