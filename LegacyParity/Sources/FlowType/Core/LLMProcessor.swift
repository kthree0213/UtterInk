import Foundation

final class LLMProcessor {
    /// 两种润色目标：日常可读 vs 再给其他 AI 用的结构化提示。
    enum TranscriptPolishKind {
        case conversational
        case structuredForDownstreamAI
    }

    private(set) var endpoint: OpenAICompatibleEndpoint
    private let session: URLSession

    init(endpoint: OpenAICompatibleEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func replaceEndpoint(_ newEndpoint: OpenAICompatibleEndpoint) {
        self.endpoint = newEndpoint
    }

    var hasUsableApiKey: Bool { endpoint.hasUsableApiKey }
    var canUseChatAPI: Bool { endpoint.canUseChatAPI }

    private static func useChineseUI() -> Bool {
        AppUILanguage.isChinese(UserDefaults.standard.string(forKey: AppUILanguage.storageKey))
    }

    private func applyAuthHeaders(to request: inout URLRequest) throws {
        let token = endpoint.normalizedApiKey()
        if endpoint.authRequired {
            guard !token.isEmpty else {
                let zh = Self.useChineseUI()
                throw NSError(
                    domain: "FlowTypeLLM",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: zh ? "未配置 API Key。" : "API key is missing."]
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in endpoint.extraHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }
    }

    private static func describeHTTPFailure(status: Int, body: Data, useChinese: Bool) -> String {
        let snippet = String(data: body, encoding: .utf8).map { String($0.prefix(320)) } ?? ""
        if status == 401 {
            let low = snippet.lowercased()
            let looksLikeMissingBearer = low.contains("cookie")
                || low.contains("authentication")
                || low.contains("unauthorized")
            if looksLikeMissingBearer {
                return useChinese
                    ? "身份验证失败（401）。请检查 API Key 是否已填写（勿含多余空格、勿重复「Bearer 」前缀），并在对应平台确认 Key 有效。"
                    : "Unauthorized (401). Check your API key (no extra spaces; paste the key only if it already includes “Bearer”)."
            }
            return useChinese
                ? "身份验证失败（401）。请检查 API Key 是否有效。"
                : "Unauthorized (401). Check that your API key is valid."
        }
        if status == 429 {
            return useChinese
                ? "请求过于频繁（429）。请稍后再试或检查服务商限流。"
                : "Too many requests (429). Wait a moment or check the provider’s rate limits."
        }
        if status >= 500 {
            return useChinese
                ? "服务端暂时不可用（\(status)）。请稍后重试。"
                : "The service is temporarily unavailable (\(status)). Try again later."
        }
        return useChinese
            ? "请求未成功（HTTP \(status)）。请检查网络、API 地址、模型名称与 Key。"
            : "Request failed (HTTP \(status)). Check your network, API URL, model id, and key."
    }

    /// 拉取当前端点下的可用模型 id。
    func fetchChatModelIdentifiers() async throws -> [String] {
        switch endpoint.modelsListStrategy {
        case .openRouterFreeOnly:
            return try await fetchOpenRouterFreeModelIdentifiers()
        case .openAICompatibleWithFallback(let fallback):
            if let fromAPI = try? await fetchOpenAIStyleModelList(), !fromAPI.isEmpty {
                return fromAPI
            }
            return fallback
        case .openAICompatibleOnly:
            if let fromAPI = try? await fetchOpenAIStyleModelList(), !fromAPI.isEmpty {
                return fromAPI
            }
            let zh = Self.useChineseUI()
            throw NSError(
                domain: "FlowTypeLLM",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: zh
                    ? "无法加载模型列表。请检查网络与填写的地址，或在下方手动填写模型名称。"
                    : "Couldn’t load the model list. Check your network and URL, or type a model name below."]
            )
        }
    }

    private func fetchOpenRouterFreeModelIdentifiers() async throws -> [String] {
        guard let url = LLMEndpointURLBuilder.url(baseURLString: endpoint.baseURLString, path: "/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        try applyAuthHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let useZh = Self.useChineseUI()
        guard httpResponse.statusCode == 200 else {
            let msg = Self.describeHTTPFailure(status: httpResponse.statusCode, body: data, useChinese: useZh)
            throw NSError(domain: "FlowTypeLLM", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataArray = json?["data"] as? [[String: Any]] ?? []
        var ids: [String] = []
        ids.reserveCapacity(dataArray.count)
        for dict in dataArray {
            guard let id = dict["id"] as? String, Self.modelLooksFreeOpenRouter(id: id, dict: dict) else { continue }
            ids.append(id)
        }
        return Self.sortFreeModelIdsOpenRouter(ids)
    }

    /// 标准 OpenAI `GET /v1/models`：`{ "data": [ { "id": "..." } ] }`
    private func fetchOpenAIStyleModelList() async throws -> [String] {
        guard let url = LLMEndpointURLBuilder.url(baseURLString: endpoint.baseURLString, path: "/models") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        try applyAuthHeaders(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataArray = json?["data"] as? [[String: Any]] ?? []
        let ids = dataArray.compactMap { $0["id"] as? String }
        return Array(Set(ids)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func process(text: String, model: String, systemPrompt: String) async throws -> String {
        let useZh = Self.useChineseUI()
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "FlowTypeLLM",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: useZh ? "该输出模式的系统提示词为空，请在设置中填写。" : "This output mode has an empty system prompt. Fill it in Settings."]
            )
        }

        var extraBody: [String: Any] = [:]
        if let temp = endpoint.chatCompletionTemperature {
            extraBody["temperature"] = temp
        }
        let data = try await postChatCompletions(
            model: model,
            messages: [
                ["role": "system", "content": trimmed],
                ["role": "user", "content": text]
            ],
            extraBody: extraBody
        )
        let raw = try Self.parseAssistantRawContent(from: data, useChinese: useZh)
        return try Self.normalizeAssistantProse(raw, useChinese: useZh)
    }

    func process(text: String, model: String, kind: TranscriptPolishKind) async throws -> String {
        let systemPrompt: String
        switch kind {
        case .conversational:
            systemPrompt = OutputModesStorage.defaultConversationalSystemPrompt
        case .structuredForDownstreamAI:
            systemPrompt = OutputModesStorage.defaultStructuredSystemPrompt
        }
        return try await process(text: text, model: model, systemPrompt: systemPrompt)
    }

    // MARK: - Request / parse

    private func postChatCompletions(model: String, messages: [[String: Any]], extraBody: [String: Any] = [:]) async throws -> Data {
        guard let url = LLMEndpointURLBuilder.url(baseURLString: endpoint.baseURLString, path: "/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        try applyAuthHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages]
        for (k, v) in extraBody { body[k] = v }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let useZh = Self.useChineseUI()
        guard httpResponse.statusCode == 200 else {
            let msg = Self.describeHTTPFailure(status: httpResponse.statusCode, body: data, useChinese: useZh)
            throw NSError(domain: "FlowTypeLLM", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    private static func parseAssistantRawContent(from data: Data, useChinese: Bool) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let err = json?["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? String(describing: err)
            let text = useChinese ? "润色请求未完成：\(msg)" : "Polish request failed: \(msg)"
            throw NSError(domain: "FlowTypeLLM", code: -1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard let json else {
            let text = useChinese ? "无法解析服务器响应。" : "Could not parse the server response."
            throw NSError(domain: "FlowTypeLLM", code: -2, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            let text = useChinese
                ? "模型没有返回可用正文。请尝试更换「润色所用模型」。"
                : "The model didn’t return usable text. Try a different polish model."
            throw NSError(domain: "FlowTypeLLM", code: -2, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let message = first["message"] as? [String: Any] ?? [:]
        if let refusal = message["refusal"] as? String, !refusal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = useChinese ? "模型拒绝生成：\(refusal)" : "Model refused: \(refusal)"
            throw NSError(domain: "FlowTypeLLM", code: -2, userInfo: [NSLocalizedDescriptionKey: text])
        }
        guard let raw = stringFromAssistantContent(message["content"]) else {
            let text = useChinese
                ? "模型没有返回正文，可能与当前供应商不搭配，请换一个模型再试。"
                : "No text came back from the model—it may not work with this provider; try another model."
            throw NSError(domain: "FlowTypeLLM", code: -2, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return raw
    }

    private static func normalizeAssistantProse(_ raw: String, useChinese: Bool) throws -> String {
        var s = stripHiddenReasoningBlocks(raw)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = stripOptionalMarkdownFence(s).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            let text = useChinese ? "模型返回了空白内容。" : "The model returned empty content."
            throw NSError(domain: "FlowTypeLLM", code: -3, userInfo: [NSLocalizedDescriptionKey: text])
        }
        var depth = 0
        while depth < 4, looksLikeJSONObjectOrArray(s) {
            if let inner = tryExtractProseFromJSONString(s) {
                s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                s = stripHiddenReasoningBlocks(s)
                s = stripOptionalMarkdownFence(s).trimmingCharacters(in: .whitespacesAndNewlines)
                depth += 1
            } else {
                let text = useChinese
                    ? "模型返回了结构化内容而不是一段可读文字。请在设置里换一个模型。"
                    : "The model returned structured content instead of plain text. Pick another model in Settings."
                throw NSError(domain: "FlowTypeLLM", code: -3, userInfo: [NSLocalizedDescriptionKey: text])
            }
        }
        if looksLikeJSONObjectOrArray(s) {
            let text = useChinese
                ? "模型仍返回结构化内容，无法当作润色结果。请更换其他模型。"
                : "The output still looks structured and can’t be used as polished text. Try a different model."
            throw NSError(domain: "FlowTypeLLM", code: -3, userInfo: [NSLocalizedDescriptionKey: text])
        }
        s = stripHiddenReasoningBlocks(s)
        return s
    }

    /// 去掉模型「思考」块，不向用户粘贴。
    /// 说明：OpenAI 兼容 `chat/completions` 通常只有 `message.content` 一段字符串，没有标准「思考」字段；
    /// 部分厂商（如 MiniMax）把内部推理嵌在 `content` 里，用 XML 风格标签包裹。
    private static func stripHiddenReasoningBlocks(_ text: String) -> String {
        let patterns = [
            // 允许标签上带属性；非贪婪匹配到闭合标签
            #"<redacted_thinking\b[^>]*>[\s\S]*?</redacted_thinking>"#,
            #"<thinking\b[^>]*>[\s\S]*?</thinking>"#,
            #"<think\b[^>]*>[\s\S]*?</think>"#,
            // 部分服务用 reason / analysis 命名
            #"<reasoning\b[^>]*>[\s\S]*?</reasoning>"#
        ]
        var s = text
        for _ in 0..<4 {
            let before = s
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]
                ) else { continue }
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
            }
            if s == before { break }
        }
        // 有开始标签但无闭合（流式或异常输出）：去掉从该标签到文末，避免整段思考漏出
        let orphanPatterns = [
            #"<redacted_thinking\b[^>]*>[\s\S]*$"#,
            #"<thinking\b[^>]*>[\s\S]*$"#,
            #"<think\b[^>]*>[\s\S]*$"#,
            #"<reasoning\b[^>]*>[\s\S]*$"#
        ]
        for pattern in orphanPatterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: "")
        }
        return s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func stringFromAssistantContent(_ content: Any?) -> String? {
        switch content {
        case let s as String:
            return s
        case let parts as [[String: Any]]:
            return joinTextParts(parts)
        case let parts as [Any]:
            var out: [String] = []
            for item in parts {
                guard let d = item as? [String: Any] else { continue }
                let type = d["type"] as? String ?? ""
                if type == "text", let t = d["text"] as? String {
                    out.append(t)
                }
            }
            return out.isEmpty ? nil : out.joined()
        case is NSNull:
            return nil
        default:
            return nil
        }
    }

    private static func joinTextParts(_ parts: [[String: Any]]) -> String? {
        var out: [String] = []
        for d in parts {
            let type = d["type"] as? String ?? ""
            if type == "text", let t = d["text"] as? String {
                out.append(t)
            }
        }
        return out.isEmpty ? nil : out.joined()
    }

    private static func stripOptionalMarkdownFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return s }
        if let firstNl = t.firstIndex(of: "\n") {
            t = String(t[t.index(after: firstNl)...])
        }
        if let endRange = t.range(of: "\n```", options: .backwards) {
            t = String(t[..<endRange.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeJSONObjectOrArray(_ s: String) -> Bool {
        guard let c = s.first(where: { !$0.isWhitespace && !$0.isNewline }) else { return false }
        return c == "{" || c == "["
    }

    private static func tryExtractProseFromJSONString(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = obj as? [String: Any] {
            let keys = ["text", "content", "message", "output", "result", "answer", "rewrite", "polished", "response", "body", "transcript"]
            for k in keys {
                if let str = dict[k] as? String {
                    let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
        }
        if let arr = obj as? [Any] {
            for item in arr {
                if let str = item as? String {
                    let t = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { return t }
                }
            }
        }
        return nil
    }

    private static func parsePrice(_ value: Any?) -> Double? {
        switch value {
        case let s as String: return Double(s)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func modelLooksFreeOpenRouter(id: String, dict: [String: Any]) -> Bool {
        if id == OpenRouterConfig.defaultChatModelId { return true }
        if id.hasSuffix(":free") { return true }
        guard let pricing = dict["pricing"] as? [String: Any] else { return false }
        let prompt = parsePrice(pricing["prompt"]) ?? 1
        let completion = parsePrice(pricing["completion"]) ?? 1
        return prompt == 0 && completion == 0
    }

    private static func sortFreeModelIdsOpenRouter(_ ids: [String]) -> [String] {
        let unique = Array(Set(ids))
        let preferredPrefixes = ["google/gemini", "qwen/", "deepseek/", "meta-llama/", "mistralai/"]
        func rank(_ id: String) -> Int {
            if id == OpenRouterConfig.defaultChatModelId { return -1_000 }
            for (i, p) in preferredPrefixes.enumerated() where id.hasPrefix(p) {
                return i
            }
            return 500
        }
        var sorted = unique.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        if !sorted.contains(OpenRouterConfig.defaultChatModelId) {
            sorted.insert(OpenRouterConfig.defaultChatModelId, at: 0)
        } else if let i = sorted.firstIndex(of: OpenRouterConfig.defaultChatModelId), i != 0 {
            sorted.remove(at: i)
            sorted.insert(OpenRouterConfig.defaultChatModelId, at: 0)
        }
        return sorted
    }
}
