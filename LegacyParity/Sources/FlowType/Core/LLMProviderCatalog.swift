import Foundation

/// 历史兼容：迁移旧版「单选预设」时用；新逻辑以 `LLMProviderProfile` 为准。
enum LLMPresetProvider: String, CaseIterable, Identifiable, Sendable {
    case openRouter = "openrouter"
    case minimax = "minimax"
    var id: String { rawValue }
    static let storageKey = "llmPresetProvider"
}

enum LLMEndpointURLBuilder {
    static func url(baseURLString: String, path: String) -> URL? {
        var base = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let p = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + p)
    }

    /// 将用户输入规范为「无末尾 /」的 OpenAI 根 URL（含 `/v1`）。
    static func normalizeOpenAIBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.hasSuffix("/v1") {
            s += "/v1"
        }
        return s
    }
}

/// 决定如何拉取 `/v1/models` 列表。
enum LLMModelsListStrategy: Sendable {
    case openRouterFreeOnly
    case openAICompatibleWithFallback([String])
    case openAICompatibleOnly
}

/// 一次润色请求所用的 OpenAI 兼容端点。
struct OpenAICompatibleEndpoint: Sendable {
    var baseURLString: String
    var apiKey: String
    var extraHeaders: [String: String]
    var pingTemperature: Double
    /// 若非 nil，在 `chat/completions` 请求体里加入 `temperature`（如 MiniMax 要求 ∈ (0,1]）。
    var chatCompletionTemperature: Double?
    /// 为 false 时允许无 Key（如本地 Ollama）；为 true 时必须有 Key。
    var authRequired: Bool
    var modelsListStrategy: LLMModelsListStrategy

    func normalizedApiKey() -> String {
        var k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "bearer "
        if k.lowercased().hasPrefix(prefix) {
            k = String(k.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return k
    }

    var hasUsableApiKey: Bool { !normalizedApiKey().isEmpty }

    /// 是否可以发起 chat（无 Key 时仅当不要求鉴权）。
    var canUseChatAPI: Bool {
        if authRequired { return hasUsableApiKey }
        return true
    }

    static func from(profile: LLMProviderProfile, apiKey: String) -> OpenAICompatibleEndpoint? {
        switch profile.template {
        case .openRouter:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://openrouter.ai/api/v1",
                apiKey: apiKey,
                extraHeaders: [
                    "HTTP-Referer": OpenRouterConfig.apiHTTPReferer,
                    "X-OpenRouter-Title": OpenRouterConfig.apiOpenRouterTitle
                ],
                pingTemperature: 0,
                chatCompletionTemperature: nil,
                authRequired: true,
                modelsListStrategy: .openRouterFreeOnly
            )
        case .minimax:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://api.minimaxi.com/v1",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 1.0,
                chatCompletionTemperature: 1.0,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.minimaxOpenAIModelIds)
            )
        case .minimaxGlobal:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://api.minimax.io/v1",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 1.0,
                chatCompletionTemperature: 1.0,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.minimaxOpenAIModelIds)
            )
        case .openAI:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.openai.com/v1", apiKey: apiKey)
        case .groq:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.groq.com/openai/v1", apiKey: apiKey)
        case .together:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.together.xyz/v1", apiKey: apiKey)
        case .deepSeek:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.deepseek.com/v1", apiKey: apiKey)
        case .moonshot:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.moonshot.cn/v1", apiKey: apiKey)
        case .siliconFlow:
            return Self.standardHostedOpenAICompatible(baseURLString: "https://api.siliconflow.cn/v1", apiKey: apiKey)
        case .alibabaQwen:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 0.01,
                chatCompletionTemperature: nil,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.dashScopeOpenAIModelIds)
            )
        case .zhipuGLM:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://open.bigmodel.cn/api/paas/v4",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 0.01,
                chatCompletionTemperature: nil,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.zhipuGLMOpenAIModelIds)
            )
        case .googleGemini:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://generativelanguage.googleapis.com/v1beta/openai",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 0.01,
                chatCompletionTemperature: nil,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.googleGeminiOpenAIModelIds)
            )
        case .volcanoArk:
            return OpenAICompatibleEndpoint(
                baseURLString: "https://ark.cn-beijing.volces.com/api/v3",
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 0.01,
                chatCompletionTemperature: nil,
                authRequired: true,
                modelsListStrategy: .openAICompatibleWithFallback(LLMPresetProviderCatalog.volcanoArkOpenAIModelIds)
            )
        case .custom:
            guard let raw = profile.customOpenAIBaseURL else { return nil }
            let base = LLMEndpointURLBuilder.normalizeOpenAIBaseURL(raw)
            guard !base.isEmpty else { return nil }
            return OpenAICompatibleEndpoint(
                baseURLString: base,
                apiKey: apiKey,
                extraHeaders: [:],
                pingTemperature: 0.01,
                chatCompletionTemperature: nil,
                authRequired: false,
                modelsListStrategy: .openAICompatibleOnly
            )
        }
    }

    /// 常见云厂商：标准 OpenAI 兼容 `/v1/chat/completions` 与 `/v1/models`。
    private static func standardHostedOpenAICompatible(baseURLString: String, apiKey: String) -> OpenAICompatibleEndpoint {
        OpenAICompatibleEndpoint(
            baseURLString: baseURLString,
            apiKey: apiKey,
            extraHeaders: [:],
            pingTemperature: 0.01,
            chatCompletionTemperature: nil,
            authRequired: true,
            modelsListStrategy: .openAICompatibleOnly
        )
    }

    /// 当前激活档案；无档案时返回 nil。
    static func fromActiveProfile() -> OpenAICompatibleEndpoint? {
        _ = LLMProfileStorage.loadProfiles()
        guard let pid = LLMProfileStorage.activeProfileId(),
              let profile = LLMProfileStorage.profile(id: pid) else { return nil }
        let key = LLMProfileStorage.apiKey(for: pid)
        return OpenAICompatibleEndpoint.from(profile: profile, apiKey: key)
    }

    /// 尚无供应商档案时的占位（避免崩溃；不可真正调用）。
    static func idlePlaceholderEndpoint() -> OpenAICompatibleEndpoint {
        OpenAICompatibleEndpoint(
            baseURLString: "https://openrouter.ai/api/v1",
            apiKey: "",
            extraHeaders: [
                "HTTP-Referer": OpenRouterConfig.apiHTTPReferer,
                "X-OpenRouter-Title": OpenRouterConfig.apiOpenRouterTitle
            ],
            pingTemperature: 0,
            chatCompletionTemperature: nil,
            authRequired: true,
            modelsListStrategy: .openRouterFreeOnly
        )
    }
}

/// MiniMax 文档列表等与模板相关的常量（避免与 `LLMProfileTemplate` 循环引用）。
enum LLMPresetProviderCatalog {
    static let minimaxOpenAIModelIds: [String] = [
        "MiniMax-M2.7",
        "MiniMax-M2.7-highspeed",
        "MiniMax-M2.5",
        "MiniMax-M2.5-highspeed",
        "MiniMax-M2.1",
        "MiniMax-M2.1-highspeed",
        "MiniMax-M2"
    ]

    /// DashScope 兼容模式常见 id（列表接口异常时的回退）。
    static let dashScopeOpenAIModelIds: [String] = [
        "qwen-turbo",
        "qwen-plus",
        "qwen-max",
        "qwen-long",
        "qwen2.5-72b-instruct"
    ]

    /// 智谱 OpenAI 兼容常见 id（`/v4` 根路径；列表失败时回退）。
    static let zhipuGLMOpenAIModelIds: [String] = [
        "glm-4-flash",
        "glm-4-air",
        "glm-4-airx",
        "glm-4",
        "glm-4-plus",
        "glm-3-turbo"
    ]

    /// Gemini OpenAI 兼容常见 id（列表接口异常时的回退）。
    static let googleGeminiOpenAIModelIds: [String] = [
        "gemini-2.0-flash",
        "gemini-2.5-flash-preview",
        "gemini-1.5-flash",
        "gemini-1.5-pro"
    ]

    /// 火山方舟 OpenAI 兼容常见模型/接入点占位名（列表失败时回退；实际以控制台为准，可为 ep-xxxx）。
    static let volcanoArkOpenAIModelIds: [String] = [
        "doubao-pro-32k",
        "doubao-lite-4k",
        "deepseek-v3-1-250821",
        "doubao-1-5-pro-32k"
    ]
}
