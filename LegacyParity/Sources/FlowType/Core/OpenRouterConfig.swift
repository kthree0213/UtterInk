import Foundation

/// OpenRouter 相关 UserDefaults 键与默认值（与设置、菜单栏 `@AppStorage` 一致）。
enum OpenRouterConfig {
    static let chatModelStorageKey = "openRouterChatModelId"
    static let defaultChatModelId = "openrouter/free"

    /// 文档建议附带来源；部分客户端若不送 `Authorization` 或来源头，可能返回 401（文案里写 cookie）。
    static let apiHTTPReferer = "http://127.0.0.1"
    static let apiOpenRouterTitle = "FlowType"
}
