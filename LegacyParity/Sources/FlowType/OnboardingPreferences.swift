import Foundation

enum OnboardingPreferences {
    /// 用户关闭引导窗口（或点跳过/完成）后会写入 `true`，之后启动不再自动弹出——与是否用 Xcode 运行无关，只要仍是同一套 UserDefaults（同一 bundle、未换容器）。
    static let dismissedKey = "onboardingDismissed"
}
