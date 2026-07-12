import Foundation

extension Notification.Name {
    /// 输出模式列表或当前选中变更后发送。
    static let outputModesDidChange = Notification.Name("outputModesDidChange")
}

/// 单条输出模式：原文模式仅 `skipsLLM == true`；其余用大模型与 `systemPrompt`。
struct OutputModeProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var skipsLLM: Bool
    var systemPrompt: String
}

enum OutputModesStorage {
    /// 内置「原文」模式，禁止改名、改 prompt、删除。
    static let builtInRawId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A101")!
    /// 安装默认：口语润色。
    static let builtInConversationalId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A102")!
    /// 安装默认：整理成提示。
    static let builtInStructuredId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A103")!
    /// 安装默认：译成中文并口语润色（同 natural chat 风格）。
    static let builtInPolishChineseId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A104")!
    /// 安装默认：译成英文并口语润色（同 natural chat 风格）。
    static let builtInPolishEnglishId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A105")!
    /// 安装默认：语音转写后润色为文言文书面语。
    static let builtInClassicalChineseId = UUID(uuidString: "E1A1A1A1-A1A1-41A1-A1A1-A1A1A1A1A106")!

    private static let modesKey = "outputModeProfilesV1"
    private static let activeIdKey = "activeOutputModeProfileId"
    /// 递增后会在下次 `loadModes` 时把各内置模式（除原文）的 `systemPrompt` 覆盖为当前代码中的默认，便于统一修正默认提示词。
    private static let builtInPromptsRevision = 2
    private static let builtInPromptsRevisionKey = "outputModesBuiltInPromptsRevision"

    static func notifyChange() {
        NotificationCenter.default.post(name: .outputModesDidChange, object: nil)
    }

    static func isBuiltInRaw(_ id: UUID) -> Bool { id == builtInRawId }

    /// 与 `LLMProcessor` 内置 conversational 一致（作默认种子与「新增模式」模板）。
    static var defaultConversationalSystemPrompt: String {
        """
        You clean up a voice transcript so it reads like a natural message the user would send in everyday chat or dialogue.

        Goals:
        - Fix word order, punctuation, and sentence breaks; split or join sentences where it helps readability.
        - Remove oral fillers and false starts (e.g. “um”, “那个”, “就是”) when they add no meaning.
        - Keep a casual, human tone. Do NOT turn it into a formal report, slide outline, or heavy bullet lists unless the user was clearly listing items.
        - Preserve facts, numbers, names, and constraints exactly; if something is ambiguous, add one short “(听不清：…)” / “(unclear: …)” note instead of guessing.
        - Language: the ENTIRE reply must match the user’s language. Chinese input → Chinese only; English → English. No gratuitous translation.

        Output rules (the app pastes your reply directly—no editing):
        - Return ONLY the final message text. Start with the first word the user would actually send—no preamble.
        - Forbidden before the real content: lines like “核心意图”, “意图”, “Intent:”, “Thinking:”, “思考”, “分析”, step-by-step reasoning, or any meta label or heading that is not part of the natural message.
        - No “Here is…”, no quotes around the whole reply unless the user explicitly asked for quoted material.
        - Plain prose only: no JSON, YAML, XML, or markdown code fences unless the user explicitly asked for that format in speech.
        """
    }

    /// 与 `defaultConversationalSystemPrompt` 相同润色目标，但输出固定为自然口语简体中文（可翻译）。
    static var defaultConversationalChineseOutputSystemPrompt: String {
        """
        You clean up a voice transcript and rewrite it so it reads like a natural message the user would send in everyday chat—in Simplified Chinese.

        Goals:
        - Fix word order, punctuation, and sentence breaks; split or join sentences where it helps readability (follow Chinese writing habits).
        - Remove oral fillers and false starts (e.g. “um”, “那个”, “就是”) when they add no meaning.
        - Keep a casual, human tone. Do NOT turn it into a formal report, slide outline, or heavy bullet lists unless the user was clearly listing items.
        - Preserve facts, numbers, names, and constraints exactly; if something is ambiguous, add one short “（听不清：…）” or “(unclear: …)” note instead of guessing.
        - Language: the ENTIRE reply must be natural, idiomatic Simplified Chinese (mainland-style casual chat). If the user spoke another language or mixed languages, translate and rewrite into Chinese. Keep well-known proper nouns / brand names in Latin letters when that is normal in Chinese chat.

        Output rules（应用会原样粘贴你的回复，请勿加可删前缀）:
        - 只输出最终要发送的正文；第一个字就是用户真正要发出去的内容，不要先写意图、分析或标题。
        - 禁止在正文前出现「核心意图」「意图」「Intent:」「Thinking:」「思考过程」等元信息或单独成段的说明。
        - 不要用 “Here is…” 包裹；除非用户口述要求加引号，否则不要给全文加引号。
        - 除用户口述要求的格式外，不要用 JSON、YAML、XML 或 markdown 代码块。
        """
    }

    /// 与 `defaultConversationalSystemPrompt` 相同润色目标，但输出固定为自然口语英文（可翻译）。
    static var defaultConversationalEnglishOutputSystemPrompt: String {
        """
        You clean up a voice transcript and rewrite it so it reads like a natural message the user would send in everyday chat—in English.

        Goals:
        - Fix word order, punctuation, and sentence breaks; split or join sentences where it helps readability.
        - Remove oral fillers and false starts (e.g. “um”, “那个”, “就是”) when they add no meaning.
        - Keep a casual, human tone. Do NOT turn it into a formal report, slide outline, or heavy bullet lists unless the user was clearly listing items.
        - Preserve facts, numbers, names, and constraints exactly; if something is ambiguous, add one short “(unclear: …)” note instead of guessing.
        - Language: the ENTIRE reply must be natural, idiomatic English for everyday messaging. If the user spoke Chinese or another language, translate and rewrite into English. Keep proper nouns in their usual English spelling when standard.

        Output rules (the app pastes your reply directly):
        - Return ONLY the final message text. Start with the first token the user would actually send—no preamble.
        - Forbidden before the real content: “核心意图”, “意图”, “Intent:”, “Thinking:”, reasoning steps, or any meta label not part of the natural message.
        - No “Here is…”, no wrapping the whole reply in quotes unless the user explicitly asked.
        - Plain prose only: no JSON, YAML, XML, or markdown code fences unless the user explicitly asked for that format in speech.
        """
    }

    /// 与 `LLMProcessor` 内置 structured 一致。
    static var defaultStructuredSystemPrompt: String {
        """
        You rewrite voice transcripts so they work well as input to another AI assistant (e.g. ChatGPT-style tools).

        Goals:
        - Turn rambling speech into clear structure: short paragraphs and bullet points where it helps the next model understand the task—without a separate “intent summary” section.
        - Weave any needed context into the body naturally; do NOT add a labeled line such as “核心意图” / “Intent:” / “Summary:” before the main text.
        - Remove fillers, repetitions, false starts, and oral hedges unless they carry meaning.
        - Preserve facts, numbers, names, and constraints exactly; if something is ambiguous, add one brief “(unclear: …)” / “（听不清：…）” note instead of inventing.
        - Language: write the ENTIRE reply in the same language as the user message. If the input is Chinese, every sentence and heading must be Chinese—do not switch to English. If the input is English, stay in English. Do not translate for “clarity” unless the user explicitly asked to translate or the input is clearly mixed on purpose.

        Output rules (FlowType pastes your reply directly into another app):
        - Return ONLY text that is ready to send—first line must be real content, not meta-analysis or intent headers.
        - Forbidden: prefixes like “核心意图”, “意图”, “Intent:”, “Thinking:”, “思考”, or any standalone “here is what you mean” paragraph before the actual message.
        - No “Here is…”, no meta commentary. Plain prose only: do NOT output JSON, YAML, XML, or markdown code fences unless the user’s speech explicitly asks for that format.
        """
    }

    /// 安装默认：口语转文言文书面语。
    static var defaultClassicalChineseSystemPrompt: String {
        """
        You clean up a voice transcript and rewrite it so it reads like an elegant, concise message in Classical Chinese (文言文).

        Goals:

        Translate and rewrite the input (whether spoken in modern Chinese, English, or another language) into authentic, highly condensed Classical Chinese.

        Remove all modern oral fillers, false starts, and redundant colloquialisms (e.g., "那个", "就是", "然后", "um").

        Tone & Style: Emphasize elegance and brevity (言简意赅). Use classical syntax, vocabulary, and particles appropriately (e.g., 吾, 汝, 乃, 遂, 之乎者也). The tone should resemble a traditional Chinese letter (尺牍) or classical dialogue.

        Do NOT use modern formatting like bullet points, slide outlines, or Arabic numerals. Convert all numbers to Chinese characters (e.g., 100 -> 百, 3 PM -> 申时 / 午后三时).

        Preserve facts, names, and constraints. For modern concepts or technology, attempt to describe them elegantly in classical terms if possible, or integrate them smoothly. If something is ambiguous, add a short note like "(未详: …)" or "(存疑: …)" instead of guessing.

        Language: The ENTIRE reply must be strictly in Classical Chinese.

        Output rules（正文将直接粘贴使用）:

        Return ONLY the rewritten Classical Chinese text—opening words must be the message itself, not a labeled intent or analysis (no “核心意图”, “Intent:”, “Thinking:”, or similar).

        No "Here is…", no paired modern translation, no meta commentary.

        Plain prose only: no JSON, YAML, XML, or markdown code fences.
        """
    }

    static func defaultSeedModes() -> [OutputModeProfile] {
        [
            OutputModeProfile(
                id: builtInRawId,
                title: "Raw (as spoken)",
                skipsLLM: true,
                systemPrompt: ""
            ),
            OutputModeProfile(
                id: builtInConversationalId,
                title: "AI polish (natural chat)",
                skipsLLM: false,
                systemPrompt: defaultConversationalSystemPrompt
            ),
            OutputModeProfile(
                id: builtInStructuredId,
                title: "AI structured (for other AI)",
                skipsLLM: false,
                systemPrompt: defaultStructuredSystemPrompt
            ),
            OutputModeProfile(
                id: builtInPolishChineseId,
                title: "AI polish to Chinese (natural chat)",
                skipsLLM: false,
                systemPrompt: defaultConversationalChineseOutputSystemPrompt
            ),
            OutputModeProfile(
                id: builtInPolishEnglishId,
                title: "AI polish to English (natural chat)",
                skipsLLM: false,
                systemPrompt: defaultConversationalEnglishOutputSystemPrompt
            ),
            OutputModeProfile(
                id: builtInClassicalChineseId,
                title: "AI rewrite to Classical Chinese (文言文)",
                skipsLLM: false,
                systemPrompt: defaultClassicalChineseSystemPrompt
            )
        ]
    }

    static func loadModes() -> [OutputModeProfile] {
        var modes: [OutputModeProfile]
        if let data = UserDefaults.standard.data(forKey: modesKey),
           let decoded = try? JSONDecoder().decode([OutputModeProfile].self, from: data),
           !decoded.isEmpty {
            modes = decoded
        } else {
            modes = defaultSeedModes()
            saveModesWithoutNotify(modes)
            if UserDefaults.standard.string(forKey: activeIdKey) == nil {
                UserDefaults.standard.set(builtInRawId.uuidString, forKey: activeIdKey)
            }
        }

        var changed = false

        if !modes.contains(where: { $0.id == builtInRawId }) {
            modes.insert(
                OutputModeProfile(id: builtInRawId, title: "Raw (as spoken)", skipsLLM: true, systemPrompt: ""),
                at: 0
            )
            changed = true
        } else if let r = modes.firstIndex(where: { $0.id == builtInRawId }), r != 0 {
            let raw = modes.remove(at: r)
            modes.insert(raw, at: 0)
            changed = true
        }

        if insertBuiltInPolishLanguageModesIfMissing(&modes) {
            changed = true
        }
        if insertBuiltInClassicalChineseIfMissing(&modes) {
            changed = true
        }

        if changed {
            saveModesWithoutNotify(modes)
        }

        if applyBuiltInPromptsRevisionIfNeeded(&modes) {
            saveModesWithoutNotify(modes)
        }

        let ids = Set(modes.map(\.id))
        if let s = UserDefaults.standard.string(forKey: activeIdKey),
           let u = UUID(uuidString: s),
           ids.contains(u) {
            // ok
        } else if let first = modes.first {
            UserDefaults.standard.set(first.id.uuidString, forKey: activeIdKey)
        }

        return modes
    }

    static func mode(id: UUID) -> OutputModeProfile? {
        loadModes().first { $0.id == id }
    }

    static func activeModeId() -> UUID? {
        let modes = loadModes()
        guard let s = UserDefaults.standard.string(forKey: activeIdKey),
              let u = UUID(uuidString: s),
              modes.contains(where: { $0.id == u }) else { return modes.first?.id }
        return u
    }

    static func activeMode() -> OutputModeProfile? {
        guard let id = activeModeId() else { return nil }
        return mode(id: id)
    }

    static func setActiveModeId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeIdKey)
        notifyChange()
    }

    static func saveModes(_ modes: [OutputModeProfile]) {
        saveModesWithoutNotify(modes)
        notifyChange()
    }

    private static func saveModesWithoutNotify(_ modes: [OutputModeProfile]) {
        if let data = try? JSONEncoder().encode(modes) {
            UserDefaults.standard.set(data, forKey: modesKey)
        }
    }

    /// 将内置模式（除原文）的提示词更新为当前包内默认；每个 `builtInPromptsRevision` 只执行一次。
    private static func applyBuiltInPromptsRevisionIfNeeded(_ modes: inout [OutputModeProfile]) -> Bool {
        let prev = UserDefaults.standard.integer(forKey: builtInPromptsRevisionKey)
        guard prev < builtInPromptsRevision else { return false }
        let updates: [UUID: String] = [
            builtInConversationalId: defaultConversationalSystemPrompt,
            builtInStructuredId: defaultStructuredSystemPrompt,
            builtInPolishChineseId: defaultConversationalChineseOutputSystemPrompt,
            builtInPolishEnglishId: defaultConversationalEnglishOutputSystemPrompt,
            builtInClassicalChineseId: defaultClassicalChineseSystemPrompt
        ]
        var touched = false
        for i in modes.indices {
            guard let p = updates[modes[i].id] else { continue }
            modes[i].systemPrompt = p
            touched = true
        }
        UserDefaults.standard.set(builtInPromptsRevision, forKey: builtInPromptsRevisionKey)
        return touched
    }

    static func deleteMode(id: UUID) {
        guard !isBuiltInRaw(id) else { return }
        var modes = loadModes()
        modes.removeAll { $0.id == id }
        saveModesWithoutNotify(modes)
        if activeModeId() == id {
            UserDefaults.standard.set(builtInRawId.uuidString, forKey: activeIdKey)
        }
        notifyChange()
    }

    /// 老版本仅有 3 条内置时补齐；插在 structured（或 conversational / raw）之后，与 `defaultSeedModes()` 顺序一致。
    private static func insertBuiltInPolishLanguageModesIfMissing(_ modes: inout [OutputModeProfile]) -> Bool {
        var changed = false
        func insertionIndexAfterCoreBuiltIns() -> Int {
            if let i = modes.firstIndex(where: { $0.id == builtInStructuredId }) { return i + 1 }
            if let i = modes.firstIndex(where: { $0.id == builtInConversationalId }) { return i + 1 }
            if let i = modes.firstIndex(where: { $0.id == builtInRawId }) { return i + 1 }
            return modes.count
        }
        if !modes.contains(where: { $0.id == builtInPolishChineseId }) {
            let pos = min(insertionIndexAfterCoreBuiltIns(), modes.count)
            modes.insert(
                OutputModeProfile(
                    id: builtInPolishChineseId,
                    title: "AI polish to Chinese (natural chat)",
                    skipsLLM: false,
                    systemPrompt: defaultConversationalChineseOutputSystemPrompt
                ),
                at: pos
            )
            changed = true
        }
        if !modes.contains(where: { $0.id == builtInPolishEnglishId }) {
            let pos: Int
            if let cn = modes.firstIndex(where: { $0.id == builtInPolishChineseId }) {
                pos = min(cn + 1, modes.count)
            } else {
                pos = min(insertionIndexAfterCoreBuiltIns(), modes.count)
            }
            modes.insert(
                OutputModeProfile(
                    id: builtInPolishEnglishId,
                    title: "AI polish to English (natural chat)",
                    skipsLLM: false,
                    systemPrompt: defaultConversationalEnglishOutputSystemPrompt
                ),
                at: pos
            )
            changed = true
        }
        return changed
    }

    private static func insertBuiltInClassicalChineseIfMissing(_ modes: inout [OutputModeProfile]) -> Bool {
        guard !modes.contains(where: { $0.id == builtInClassicalChineseId }) else { return false }
        let pos: Int
        if let i = modes.firstIndex(where: { $0.id == builtInPolishEnglishId }) {
            pos = min(i + 1, modes.count)
        } else if let i = modes.firstIndex(where: { $0.id == builtInPolishChineseId }) {
            pos = min(i + 1, modes.count)
        } else if let i = modes.firstIndex(where: { $0.id == builtInStructuredId }) {
            pos = min(i + 1, modes.count)
        } else {
            pos = modes.count
        }
        modes.insert(
            OutputModeProfile(
                id: builtInClassicalChineseId,
                title: "AI rewrite to Classical Chinese (文言文)",
                skipsLLM: false,
                systemPrompt: defaultClassicalChineseSystemPrompt
            ),
            at: pos
        )
        return true
    }
}

extension OutputModeProfile {
    /// 内置原文在菜单/设置中随界面语言展示固定文案；其余模式用用户自定的 `title`。
    func displayTitle(useChinese: Bool) -> String {
        if id == OutputModesStorage.builtInRawId {
            return useChinese ? "原文（说什么出什么）" : "Raw (as spoken)"
        }
        if id == OutputModesStorage.builtInClassicalChineseId {
            return useChinese ? "文言文（古汉语书面）" : "Classical Chinese (literary)"
        }
        return title
    }
}
