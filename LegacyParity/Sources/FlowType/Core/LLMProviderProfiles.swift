import Foundation

extension Notification.Name {
    /// 供应商列表、当前选中、Key 或模型变更后发送，用于刷新菜单与 Coordinator。
    static let llmProviderProfilesDidChange = Notification.Name("llmProviderProfilesDidChange")
}

/// 配置档案类型：常见 OpenAI 兼容云厂商预设，或任意自定义 Base URL。
enum LLMProfileTemplate: String, Codable, CaseIterable, Identifiable {
    case openRouter = "openrouter"
    case openAI = "openai"
    case groq = "groq"
    case together = "together"
    /// 国内站 OpenAI 兼容（`api.minimaxi.com`）；与 `minimaxGlobal` 账号与 Key 不互通。
    case minimax = "minimax"
    /// 国际站 OpenAI 兼容（`api.minimax.io`）；与 `minimax` 账号与 Key 不互通。
    case minimaxGlobal = "minimax_global"
    case deepSeek = "deepseek"
    case moonshot = "moonshot"
    case siliconFlow = "siliconflow"
    /// 阿里云 DashScope OpenAI 兼容模式（通义千问等）。
    case alibabaQwen = "alibaba_qwen"
    /// 智谱 OpenAI 兼容（GLM，`/v4` 根路径）。
    case zhipuGLM = "zhipu_glm"
    /// Google Gemini（Google AI Studio / Gemini API 的 OpenAI 兼容入口）。
    case googleGemini = "google_gemini"
    /// 火山引擎火山方舟，OpenAI 兼容 `api/v3`。
    case volcanoArk = "volcano_ark"
    case custom = "custom"

    var id: String { rawValue }

    func displayName(useChinese: Bool) -> String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .groq: return "Groq"
        case .together: return "Together AI"
        case .minimax: return useChinese ? "MiniMax（国内）" : "MiniMax (China)"
        case .minimaxGlobal: return useChinese ? "MiniMax（国际）" : "MiniMax (Global)"
        case .deepSeek: return "DeepSeek"
        case .moonshot: return useChinese ? "Moonshot（月之暗面）" : "Moonshot"
        case .siliconFlow: return useChinese ? "硅基流动 SiliconFlow" : "SiliconFlow"
        case .alibabaQwen: return useChinese ? "阿里通义（DashScope）" : "Alibaba Qwen (DashScope)"
        case .zhipuGLM: return useChinese ? "智谱 GLM" : "Zhipu GLM"
        case .googleGemini: return useChinese ? "Google（Gemini）" : "Google (Gemini)"
        case .volcanoArk: return useChinese ? "火山引擎（方舟）" : "Volcano Engine (Ark)"
        case .custom: return useChinese ? "自定义" : "Custom"
        }
    }

    /// 非 `custom` 时为固定 OpenAI 兼容根路径，供界面只读展示。
    var fixedOpenAIBaseURL: String? {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .together: return "https://api.together.xyz/v1"
        case .minimax: return "https://api.minimaxi.com/v1"
        case .minimaxGlobal: return "https://api.minimax.io/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .siliconFlow: return "https://api.siliconflow.cn/v1"
        case .alibabaQwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .zhipuGLM: return "https://open.bigmodel.cn/api/paas/v4"
        case .googleGemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .volcanoArk: return "https://ark.cn-beijing.volces.com/api/v3"
        case .custom: return nil
        }
    }

    var defaultModelId: String {
        switch self {
        case .openRouter: return OpenRouterConfig.defaultChatModelId
        case .openAI: return "gpt-4o-mini"
        case .groq: return "llama-3.3-70b-versatile"
        case .together: return "meta-llama/Llama-3.1-8B-Instruct-Turbo"
        case .minimax, .minimaxGlobal: return "MiniMax-M2.7"
        case .deepSeek: return "deepseek-chat"
        case .moonshot: return "moonshot-v1-8k"
        case .siliconFlow: return "Qwen/Qwen2.5-7B-Instruct"
        case .alibabaQwen: return "qwen-turbo"
        case .zhipuGLM: return "glm-4-flash"
        case .googleGemini: return "gemini-2.0-flash"
        case .volcanoArk: return "doubao-pro-32k"
        case .custom: return "default"
        }
    }
}

/// 用户可配置多条；菜单与润色均基于「当前激活」档案。
struct LLMProviderProfile: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var title: String
    var template: LLMProfileTemplate
    /// 仅 `template == .custom` 时使用；预设模板的地址由 `LLMProfileTemplate.fixedOpenAIBaseURL` 决定。
    var customOpenAIBaseURL: String?

    /// 列表与菜单展示用：`title` 可为空以便在输入框里整段改名；空则回退为模板名称。
    func resolvedTitle(useChinese: Bool) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return template.displayName(useChinese: useChinese)
    }
}

enum LLMProfileStorage {
    private static let profilesKey = "llmProviderProfilesV1"
    private static let activeIdKey = "llmActiveProviderProfileId"
    private static let migratedKey = "llmProviderProfilesMigratedV1"

    private static func apiKeyKey(_ id: UUID) -> String { "llmP.\(id.uuidString).apiKey" }
    private static func modelKey(_ id: UUID) -> String { "llmP.\(id.uuidString).modelId" }
    private static func modelsCacheKey(_ id: UUID) -> String { "llmP.\(id.uuidString).modelsCache" }

    static func notifyChange() {
        NotificationCenter.default.post(name: .llmProviderProfilesDidChange, object: nil)
    }

    static func loadProfiles() -> [LLMProviderProfile] {
        migrateIfNeeded()
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let list = try? JSONDecoder().decode([LLMProviderProfile].self, from: data) else {
            return []
        }
        return list
    }

    static func saveProfiles(_ profiles: [LLMProviderProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        notifyChange()
    }

    static func profile(id: UUID) -> LLMProviderProfile? {
        loadProfiles().first { $0.id == id }
    }

    static func activeProfileId() -> UUID? {
        migrateIfNeeded()
        guard let s = UserDefaults.standard.string(forKey: activeIdKey), let u = UUID(uuidString: s) else { return nil }
        return loadProfiles().contains(where: { $0.id == u }) ? u : loadProfiles().first?.id
    }

    static func setActiveProfileId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeIdKey)
        notifyChange()
    }

    static func apiKey(for id: UUID) -> String {
        UserDefaults.standard.string(forKey: apiKeyKey(id)) ?? ""
    }

    static func setApiKey(_ key: String, for id: UUID) {
        UserDefaults.standard.set(key, forKey: apiKeyKey(id))
        notifyChange()
    }

    static func modelId(for id: UUID) -> String {
        let d = profile(id: id)?.template.defaultModelId ?? OpenRouterConfig.defaultChatModelId
        return UserDefaults.standard.string(forKey: modelKey(id)) ?? d
    }

    static func setModelId(_ model: String, for id: UUID) {
        UserDefaults.standard.set(model, forKey: modelKey(id))
        notifyChange()
    }

    static func modelsCache(for id: UUID) -> [String]? {
        guard let data = UserDefaults.standard.data(forKey: modelsCacheKey(id)),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return arr
    }

    static func setModelsCache(_ models: [String], for id: UUID) {
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: modelsCacheKey(id))
        }
        ensureDefaultLLMSelectionIfNeeded()
        notifyChange()
    }

    /// 全局仅一条可选模型、或当前选中组合不在任何已拉取的列表里时，自动选中合理项（菜单栏与设置拉取列表后都会用到）。
    static func ensureDefaultLLMSelectionIfNeeded() {
        let profiles = menuVisibleProfiles()
        var pairs: [(UUID, String)] = []
        for p in profiles {
            guard let models = modelsCache(for: p.id), !models.isEmpty else { continue }
            for m in models {
                pairs.append((p.id, m))
            }
        }
        guard !pairs.isEmpty else { return }

        let aid = activeProfileId()
        let curModel = aid.map { modelId(for: $0) } ?? ""
        let curOk: Bool = {
            guard let a = aid, let ms = modelsCache(for: a) else { return false }
            return ms.contains(curModel)
        }()

        if pairs.count == 1 {
            let (pid, mid) = pairs[0]
            if aid != pid || curModel != mid {
                setActiveProfileId(pid)
                setModelId(mid, for: pid)
            }
            return
        }

        if !curOk {
            if let a = aid, let ms = modelsCache(for: a), let m = ms.first {
                setModelId(m, for: a)
                return
            }
            if let first = pairs.first {
                setActiveProfileId(first.0)
                setModelId(first.1, for: first.0)
            }
        }
    }

    /// 可在菜单中展示的档案：云预设需已填 Key；自定义需已填 Base URL。
    static func menuVisibleProfiles() -> [LLMProviderProfile] {
        loadProfiles().filter { p in
            if p.template == .custom {
                guard let u = p.customOpenAIBaseURL else { return false }
                return !u.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return !apiKey(for: p.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func addProfile(_ profile: LLMProviderProfile, apiKey: String = "", modelId: String? = nil) {
        var list = loadProfiles()
        list.append(profile)
        saveProfiles(list)
        setApiKey(apiKey, for: profile.id)
        if let m = modelId {
            setModelId(m, for: profile.id)
        } else {
            setModelId(profile.template.defaultModelId, for: profile.id)
        }
        if activeProfileId() == nil {
            setActiveProfileId(profile.id)
        }
    }

    static func updateProfile(_ profile: LLMProviderProfile) {
        var list = loadProfiles()
        guard let i = list.firstIndex(where: { $0.id == profile.id }) else { return }
        list[i] = profile
        saveProfiles(list)
    }

    static func deleteProfile(id: UUID) {
        let list = loadProfiles().filter { $0.id != id }
        let wasActive = UserDefaults.standard.string(forKey: activeIdKey) == id.uuidString
        UserDefaults.standard.removeObject(forKey: apiKeyKey(id))
        UserDefaults.standard.removeObject(forKey: modelKey(id))
        UserDefaults.standard.removeObject(forKey: modelsCacheKey(id))
        saveProfiles(list)
        if wasActive {
            if let first = list.first {
                setActiveProfileId(first.id)
            } else {
                UserDefaults.standard.removeObject(forKey: activeIdKey)
                notifyChange()
            }
        }
    }

    private static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)

        if UserDefaults.standard.data(forKey: profilesKey) != nil { return }

        var profiles: [LLMProviderProfile] = []
        let orId = UUID()
        let orKey = UserDefaults.standard.string(forKey: "openRouterApiKey") ?? ""
        let orModel = UserDefaults.standard.string(forKey: OpenRouterConfig.chatModelStorageKey) ?? OpenRouterConfig.defaultChatModelId
        profiles.append(LLMProviderProfile(id: orId, title: "OpenRouter", template: .openRouter, customOpenAIBaseURL: nil))
        UserDefaults.standard.set(orKey, forKey: apiKeyKey(orId))
        UserDefaults.standard.set(orModel, forKey: modelKey(orId))

        let mmKey = UserDefaults.standard.string(forKey: "minimaxApiKey") ?? ""
        if !mmKey.isEmpty {
            let mmId = UUID()
            let mmModel = UserDefaults.standard.string(forKey: "minimaxChatModelId") ?? LLMProfileTemplate.minimax.defaultModelId
            profiles.append(LLMProviderProfile(id: mmId, title: "MiniMax", template: .minimax, customOpenAIBaseURL: nil))
            UserDefaults.standard.set(mmKey, forKey: apiKeyKey(mmId))
            UserDefaults.standard.set(mmModel, forKey: modelKey(mmId))
        }

        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }

        let oldPreset = UserDefaults.standard.string(forKey: LLMPresetProvider.storageKey) ?? LLMPresetProvider.openRouter.rawValue
        if oldPreset == LLMPresetProvider.minimax.rawValue, profiles.count > 1 {
            UserDefaults.standard.set(profiles[1].id.uuidString, forKey: activeIdKey)
        } else {
            UserDefaults.standard.set(orId.uuidString, forKey: activeIdKey)
        }
    }
}
