import Foundation

enum AppUILanguage {
    static let storageKey = "uiLanguage"

    static func isChinese(_ code: String?) -> Bool {
        (code ?? "en") == "zh"
    }
}

/// 随界面语言切换的文案（菜单栏、灵动岛等用 `useChinese` / `uiLanguage` 驱动刷新）。
struct MenuLocalization {
    var useChinese: Bool

    var enableVoiceInput: String { useChinese ? "启用FlowType" : "Enable FlowType" }
    var outputMode: String { useChinese ? "输出模式" : "Output Mode" }
    var llmModel: String { useChinese ? "大语言模型" : "LLM Model" }
    /// 与设置「通用」中选项同义：Whisper 优先识别语种。
    var transcriptionLanguage: String { SpeechTranscriptionSettings.userFacingLabel(useChinese: useChinese) }
    var speechModel: String { useChinese ? "语音转写模型" : "Speech Model" }
    var setupOpenRouter: String { useChinese ? "配置模型供应商…" : "Configure LLM provider…" }
    var settings: String { useChinese ? "设置" : "Settings" }
    var quit: String { useChinese ? "退出" : "Quit" }
    var processing: String { useChinese ? "处理中…" : "Processing…" }
    var listening: String { useChinese ? "聆听中…" : "Listening…" }
    var openAXSettings: String { useChinese ? "打开辅助功能设置…" : "Open Accessibility Settings…" }
    var openMicrophonePrivacy: String { useChinese ? "打开麦克风隐私设置…" : "Open Microphone Privacy…" }
    var downloadingModel: String { useChinese ? "正在下载模型" : "Downloading model" }
    var loadingModel: String { useChinese ? "正在加载模型" : "Loading model" }
    var setupGuide: String { useChinese ? "首次设置…" : "Setup Guide…" }

    // MARK: - 灵动岛 · 麦克风
    /// 待机时麦克风旁弱化提示。
    var dynamicIslandHintIdle: String { useChinese ? "点击开始录音" : "Tap to record" }
    /// 录音中提示如何结束。
    var dynamicIslandHintRecording: String { useChinese ? "再次点击停止" : "Tap again to stop" }
    /// 麦克风图标下方常驻短说明。
    var dynamicIslandMicFootnote: String { useChinese ? "点击开始，再次点击停止" : "Tap to start · tap again to stop" }
    /// 首次展示的气泡说明（点麦克风后消失）。
    var dynamicIslandFirstCallout: String {
        useChinese
            ? "点击麦克风开始录音，说完后再点一次结束。"
            : "Tap the mic to start; tap again when you’re done."
    }
    /// 悬停麦克风时的帮助（Tooltip）。
    var dynamicIslandMicHelp: String {
        useChinese
            ? "点击开始录音，再次点击停止并转写。"
            : "Click to start recording; click again to stop and transcribe."
    }
}

/// 首次启动引导（与界面语言一致）。
struct OnboardingLocalization {
    var useChinese: Bool

    var windowTitle: String { useChinese ? "欢迎使用 FlowType" : "Welcome to FlowType" }
    var skip: String { useChinese ? "跳过" : "Skip" }
    var back: String { useChinese ? "上一步" : "Back" }
    var next: String { useChinese ? "下一步" : "Next" }
    var done: String { useChinese ? "完成" : "Done" }

    var stepWelcomeTitle: String { useChinese ? "FlowType 是做什么的？" : "What is FlowType?" }
    var stepWelcomeBody: String {
        useChinese
            ? "你可以把它想成「用嘴打字」：它住在菜单栏，按下快捷键就能对着 Mac 说话，说的话会变成文字，自动贴进你正在输入的地方——回消息、写邮件、记笔记都行。语音在你自己的电脑上识别，录音不会上传。后面几步会请你打开麦克风和粘贴所需的系统权限，并一起选好语种和语音模型；不着急配 AI 也没关系，先走完就能用，细节随时在设置里改。"
            : "Think of it as typing with your voice: FlowType lives in the menu bar—press your shortcut, speak, and your words appear as text right where you’re typing (messages, mail, notes, …). Recognition runs on your Mac; your voice isn’t uploaded. Next steps will ask for Microphone and Accessibility, then help you pick language and a speech model. You don’t need to set up AI polish yet—you can use the app after this tour and tweak everything in Settings."
    }

    var stepAXTitle: String { useChinese ? "辅助功能" : "Accessibility" }
    var stepAXBody: String {
        useChinese
            ? "向其他应用粘贴时，本应用会模拟 Command+V。请打开「系统设置 → 隐私与安全性 → 辅助功能」，在列表中找到 FlowType 并打开开关。若出现多个同名条目，请勾选位于「应用程序」文件夹里的那一项（下方路径供核对）。"
            : "Pasting simulates Command+V. Open System Settings → Privacy & Security → Accessibility, find FlowType, and turn it on. If several entries share the name, enable the one inside your Applications folder (verify with the path below)."
    }
    var stepAXOpen: String { useChinese ? "打开辅助功能设置" : "Open Accessibility Settings" }
    var stepAXStatusOn: String { useChinese ? "已为 FlowType 开启辅助功能" : "Accessibility is on for FlowType" }
    var stepAXStatusOff: String { useChinese ? "尚未开启辅助功能" : "Accessibility is not enabled yet" }

    var stepMicTitle: String { useChinese ? "麦克风" : "Microphone" }
    var stepMicBody: String {
        useChinese
            ? "录音转写需要麦克风权限。可点击下方按钮打开「隐私与安全性 → 麦克风」，为 FlowType 打开开关。"
            : "Transcription needs microphone access. Use the button below to open Privacy & Security → Microphone and enable FlowType."
    }
    var stepMicOpen: String { useChinese ? "打开麦克风隐私设置" : "Open Microphone Privacy" }
    var stepMicGranted: String { useChinese ? "已授权" : "Allowed" }
    var stepMicDenied: String { useChinese ? "未授权 / 未决定" : "Not allowed / not determined" }

    /// 引导：优先识别语种（与「设置 → 通用」同步）。
    var stepUsualLanguageTitle: String { useChinese ? "优先识别语种" : "Primary language" }
    var stepUsualLanguageBody: String {
        useChinese
            ? "与「设置 → 通用」中的选项一致。这里是给 Whisper 的优先提示，帮助减少误判，并非限制你只能说这一种话；中英夹杂通常仍可识别。若说话语种经常切换，可开启自动识别。此处选择可随时在设置里更改。"
            : "Same as Settings → General. This is a priority hint for Whisper to cut down mishears—it doesn’t mean you can only speak that language, and mixed speech often still works. Turn on auto-detect if you switch languages a lot. You can change this anytime in Settings."
    }

    var stepShortcutTitle: String { useChinese ? "快捷键" : "Shortcuts" }
    var stepShortcutBody: String {
        useChinese
            ? "默认快捷键为 Option+空格，可在「设置 → 快捷键」修改。本应用仅支持用 Control（⌃）或 Option（⌥）配合字母、数字或空格等键。录制时请从菜单栏打开本设置窗口并置于前台，再点击录制框。"
            : "Default is Option+Space—change it under Settings → Shortcuts. Only Control (⌃) or Option (⌥) plus a letter, number, or Space is supported. Open Settings from the menu bar, keep this window frontmost, then click the recorder."
    }
    var stepShortcutOpenSettings: String { useChinese ? "打开设置" : "Open Settings" }

    var stepWhisperTitle: String { useChinese ? "语音转写模型（Whisper）" : "Speech model (Whisper)" }
    var stepWhisperBody: String {
        useChinese
            ? "语音转写完全在本机进行，录音不会上传。Whisper 模型文件首次使用需联网下载到本机，之后可离线转写。可在「设置 → 语音模型」查看各档说明与体积、下载或切换；文件保存在本机「资源库 → Application Support → FlowType」。若默认档位不合适，随时可在设置里更换。"
            : "Speech-to-text stays on your device—audio is never uploaded. Whisper model files download once over the network the first time you use a variant, then transcription works offline. Open Settings → Speech Model for sizes and descriptions, download or switch variants; files live under Library/Application Support/FlowType on your Mac. You can change the model anytime."
    }
    var stepWhisperCurrentLabel: String { useChinese ? "当前将使用的模型：" : "Model being prepared: " }

    var stepOutputModesTitle: String { useChinese ? "输出模式" : "Output modes" }
    var stepOutputModesBody: String {
        useChinese
            ? "每次说完话，你可以只要「原文」，也可以让大模型按你的提示词把字改一改、理一理——每一种做法就是一个输出模式。选「原文」最快，也不用配任何 API Key；要用 AI 润色或整理，再到「设置 → 模型供应商」里加服务商即可。模式名称、提示词都能在「设置 → 输出模式」里改，也可以新增自己的模式，菜单栏里的选项与那里一致。"
            : "After each session you can paste the transcript as-is, or run it through a model with a prompt—each combination is an output mode. Raw is fastest and needs no API key; for polish or cleanup, add a provider under Settings → LLM Provider. Rename modes, edit prompts, or add your own under Settings → Output Modes; the menu bar matches what you mark in use there."
    }
    var stepOutputModesOpenSettings: String { useChinese ? "打开设置（输出模式）…" : "Open Settings (Output Modes)…" }

    var pathLabel: String { useChinese ? "应用位置（与系统设置中的列表对照）" : "App location (match in System Settings)" }
}

struct SettingsLocalization {
    var useChinese: Bool

    var generalTab: String { useChinese ? "通用" : "General" }
    var shortcutsTab: String { useChinese ? "快捷键" : "Shortcuts" }
    /// 设置 → 快捷键：分组标题（与「通用」页 Section header 风格一致）。
    var shortcutsSettingsSectionTitle: String { useChinese ? "触发与快捷键" : "Trigger & shortcut" }
    /// 设置 → 快捷键：触发方式行标题。
    var shortcutsTriggerModeLabel: String { useChinese ? "触发方式" : "Trigger mode" }
    /// 设置 → 快捷键：点按切换（菜单短名）。
    var shortcutsTriggerOptionToggle: String { useChinese ? "点按切换" : "Toggle" }
    /// 设置 → 快捷键：按住说话（菜单短名）。
    var shortcutsTriggerOptionPushToTalk: String { useChinese ? "按住说话" : "Hold to talk" }
    /// 设置 → 快捷键：点按切换模式的说明。
    var shortcutsTriggerToggleExplanation: String {
        useChinese
            ? "按一次快捷键开始录音，再按一次结束并转写。双手在键盘上时很方便，不必长按。"
            : "Press the shortcut once to start recording, press again to stop and transcribe—no need to hold the key."
    }
    /// 设置 → 快捷键：按住说话模式的说明。
    var shortcutsTriggerPushToTalkExplanation: String {
        useChinese
            ? "按住快捷键期间录音，松开即结束并转写。像对讲机，可避免忘记再按一次而一直录下去。"
            : "Hold the shortcut while you speak; release to stop and transcribe—walkie-talkie style, so you don’t leave recording on by mistake."
    }
    /// 设置 → 快捷键：录制器行标题。
    var shortcutsRecorderLabel: String { useChinese ? "快捷键" : "Keyboard shortcut" }
    /// 快捷键 Tab：仅 ⌃/⌥ 可设快捷键；文案在录制行下方展示。
    var shortcutsCombinationHint: String {
        useChinese
            ? "本应用仅支持 Control（⌃）或 Option（⌥）与字母、数字或空格等键组合。从菜单栏打开本窗口并置于前台后再点录制框；不要只按单键。"
            : "Only Control (⌃) or Option (⌥) with a letter, number, or Space works here. Open Settings from the menu bar, keep this window frontmost, then click the recorder—don’t press a single key alone."
    }
    var openRouterTab: String { useChinese ? "OpenRouter" : "OpenRouter" }
    /// 设置 Tab：模型供应商（OpenRouter / MiniMax 等）。
    var llmProviderTab: String { useChinese ? "模型供应商" : "LLM Provider" }
    var llmProviderPicker: String { useChinese ? "供应商" : "Provider" }
    var llmRefreshModels: String { useChinese ? "加载模型列表" : "Load model list" }
    var llmLoadModelsFootnote: String {
        useChinese
            ? "仅从服务商同步可选模型并更新下方菜单，当没有获取可选模型时，可以手动填写模型名称。"
            : "Fetches the provider’s model list and updates the picker below. If no list is returned, you can type a model name manually."
    }
    func llmProviderHint(template: LLMProfileTemplate) -> String {
        switch template {
        case .openRouter:
            return useChinese
                ? "每次会从 OpenRouter 同步最新列表。仅显示当前可免费使用的对话模型；名单随官方政策变化。"
                : "Each click syncs the latest list from OpenRouter. Only free/zero-price chat models; the lineup changes with OpenRouter’s policy."
        case .openAI:
            return useChinese
                ? "OpenAI 官方服务（api.openai.com）。在 platform.openai.com 创建 Key；点击「加载模型列表」可同步可用模型。"
                : "Official OpenAI (api.openai.com). Create a key on platform.openai.com; tap Load model list to sync available models."
        case .groq:
            return useChinese
                ? "Groq（api.groq.com）。在 console.groq.com 获取 Key，速度通常较快。"
                : "Groq (api.groq.com). Get a key from console.groq.com; usually very fast."
        case .together:
            return useChinese
                ? "Together AI（api.together.xyz），聚合多种开源模型。在 together.ai 创建 API Key。"
                : "Together AI (api.together.xyz) hosts many open models. Create an API key on together.ai."
        case .minimax:
            return useChinese
                ? "MiniMax 国内站（api.minimaxi.com）。在 minimaxi.com 控制台创建 Key；国内与国际账号不互通，勿混用。若加载模型列表失败，可在下方手写模型名。"
                : "MiniMax China (api.minimaxi.com). Create a key on minimaxi.com; China and global accounts are separate. If the model list fails to load, type a model name manually below."
        case .minimaxGlobal:
            return useChinese
                ? "MiniMax 国际站（api.minimax.io）。在 platform.minimax.io 创建 Key；与国内站不互通。若加载模型列表失败，可在下方手写模型名。"
                : "MiniMax global (api.minimax.io). Create a key on platform.minimax.io; not interchangeable with the China console. If the model list fails to load, type a model name manually below."
        case .deepSeek:
            return useChinese
                ? "DeepSeek（api.deepseek.com）。在 platform.deepseek.com 获取 Key。"
                : "DeepSeek (api.deepseek.com). Get a key from platform.deepseek.com."
        case .moonshot:
            return useChinese
                ? "月之暗面 Moonshot（api.moonshot.cn）。在 platform.moonshot.cn 创建 Key。"
                : "Moonshot (api.moonshot.cn). Create a key on platform.moonshot.cn."
        case .siliconFlow:
            return useChinese
                ? "硅基流动 SiliconFlow（api.siliconflow.cn），聚合多类开源模型。在 siliconflow.cn 获取 Key。"
                : "SiliconFlow (api.siliconflow.cn) hosts many models. Get a key from siliconflow.cn."
        case .alibabaQwen:
            return useChinese
                ? "阿里云 DashScope（通义千问）。在 dashscope.console.aliyun.com 获取 API-Key；若加载模型列表失败，会给出常见模型名供选择。"
                : "Alibaba DashScope (Qwen). Get an API key from dashscope.console.aliyun.com; if the model list fails to load, common Qwen names are offered as fallback."
        case .zhipuGLM:
            return useChinese
                ? "智谱 GLM。在 open.bigmodel.cn 创建 API Key；若加载模型列表失败，会给出常见 GLM 模型名供选择。"
                : "Zhipu GLM. Create a key on open.bigmodel.cn; if the model list fails to load, common GLM names are offered as fallback."
        case .googleGemini:
            return useChinese
                ? "Google Gemini。在 Google AI Studio 创建 API Key；若加载模型列表失败，会给出常见 Gemini 模型名供选择。"
                : "Google Gemini. Create an API key in Google AI Studio; if the model list fails to load, common Gemini names are offered as fallback."
        case .volcanoArk:
            return useChinese
                ? "火山引擎方舟。在控制台创建 API Key；润色模型常为接入点 ID（如 ep-xxxx）。若加载模型列表失败，会给出常见名称供选择。"
                : "Volcano Ark. Create an API key in the console; the polish model is often an endpoint id (e.g. ep-xxxx). If the model list fails to load, common names are offered as fallback."
        case .custom:
            return useChinese
                ? "填写服务商提供的 API 根地址（若未写全，应用会尽量补全常见后缀）。API Key 可留空（如仅本机服务）。若无法加载模型列表，请在下方手动填写模型名。"
                : "Paste the API base URL from your provider (the app may fill in common suffixes if needed). API key is optional for some local setups. If the model list doesn’t load, type a model name manually below."
        }
    }

    var llmProfileList: String { useChinese ? "供应商档案" : "Provider profiles" }
    /// 当前用于录音结束后 AI 润色 / 整理的档案（展示在左侧列表旁）。
    var llmPolishDefaultBadge: String { useChinese ? "使用中" : "In use" }
    var llmSetAsPolishDefault: String { useChinese ? "使用" : "Use" }
    var llmProfileListFootnote: String {
        useChinese
            ? "在这里添加并选择你要使用的大语言模型供应商；点选左侧一行可在右侧编辑该供应商的 Key、加载模型等。"
            : "Add and choose your LLM providers here. Select a row on the left to edit keys, load models, and more on the right."
    }
    var llmSelectProfileOnLeft: String { useChinese ? "请在左侧选择一条档案。" : "Select a profile in the list on the left." }
    var llmAddProvider: String { useChinese ? "添加…" : "Add…" }
    var llmApiEndpoint: String { useChinese ? "服务地址（固定）" : "Service URL (fixed)" }
    var llmAddOpenRouter: String { "OpenRouter" }
    var llmAddOpenAI: String { "OpenAI" }
    var llmAddGroq: String { "Groq" }
    var llmAddTogether: String { "Together AI" }
    var llmAddMiniMaxChina: String { useChinese ? "MiniMax（国内）" : "MiniMax (China)" }
    var llmAddMiniMaxGlobal: String { useChinese ? "MiniMax（国际）" : "MiniMax (Global)" }
    var llmAddDeepSeek: String { "DeepSeek" }
    var llmAddMoonshot: String { useChinese ? "Moonshot（月之暗面）" : "Moonshot" }
    var llmAddSiliconFlow: String { useChinese ? "硅基流动 SiliconFlow" : "SiliconFlow" }
    var llmAddAlibabaQwen: String { useChinese ? "阿里通义（DashScope）" : "Alibaba Qwen (DashScope)" }
    var llmAddZhipuGLM: String { useChinese ? "智谱 GLM" : "Zhipu GLM" }
    var llmAddGoogleGemini: String { useChinese ? "Google（Gemini）" : "Google (Gemini)" }
    var llmAddVolcanoArk: String { useChinese ? "火山引擎（方舟）" : "Volcano Engine (Ark)" }
    var llmAddCustom: String { useChinese ? "自定义服务商" : "Custom provider" }
    var llmDeleteProfile: String { useChinese ? "删除档案" : "Delete profile" }
    var llmProfileTitle: String { useChinese ? "显示名称" : "Display name" }
    var llmCustomBaseURL: String { useChinese ? "服务根地址" : "Service base URL" }
    var llmApiKeyOptional: String { useChinese ? "API Key（可选）" : "API key (optional)" }
    var llmApiKeyRequired: String { useChinese ? "API Key" : "API key" }
    var llmProfilesEmpty: String {
        useChinese
            ? "暂无档案。点击下方「添加…」任选预设（含 Google、火山、通义、智谱等）或自定义地址。"
            : "No profiles yet. Use Add… to pick a preset (incl. Google, Volcano, Qwen, Zhipu, …) or a custom base URL."
    }
    var llmManualModelField: String { useChinese ? "模型名称（下拉为空时在此填写）" : "Model name (if the menu is empty)" }
    var speechTab: String { useChinese ? "语音模型" : "Speech Model" }

    var interfaceLanguage: String { useChinese ? "界面语言" : "Interface language" }
    var speechRecognitionLanguage: String { SpeechTranscriptionSettings.userFacingLabel(useChinese: useChinese) }
    var speechRecognitionHint: String { SpeechTranscriptionSettings.userFacingExplanation(useChinese: useChinese) }
    /// 通用：开启后由 Whisper 自动判断语种。
    var speechAutoDetectLabel: String { useChinese ? "自动识别语种" : "Auto-detect language" }
    /// 通用：自动识别开关下方短说明。
    var speechAutoDetectCaption: String {
        useChinese
            ? "开启后由 Whisper 自动判断语种，不再使用上方「优先识别语种」的固定提示，适合说话语种经常变化。若识别异常，请到「语音模型」看看是否选用了仅英语（名称带 .en）的变体，或尝试换成更大、更强的模型。"
            : "When on, Whisper detects the language and ignores the Primary language setting above—handy if you switch languages often. If results look wrong, open Speech Model and check for an English-only (.en) variant, or try a larger, more capable model."
    }
    /// 菜单栏：更多语言入口。
    var speechMoreLanguagesInSettings: String {
        useChinese ? "在「设置 → 通用」中选择更多语言…" : "More languages in Settings → General…"
    }

    /// 设置 → 通用：界面与识别分组标题。
    var generalLanguageSectionTitle: String { useChinese ? "界面与识别" : "Interface & recognition" }
    /// 设置 → 通用：系统权限分组标题。
    var generalPermissionsSectionTitle: String { useChinese ? "系统权限" : "System permissions" }
    /// 设置 → 通用：权限分组底部说明（承接上一段，减少突兀感）。
    var generalPermissionsSectionFooter: String {
        useChinese
            ? "麦克风用于录音转写；辅助功能用于向其他应用粘贴文字。从系统设置返回本窗口后，状态会自动更新。"
            : "Microphone is for recording and transcription; Accessibility is for pasting text into other apps. Status refreshes when you return to this window from System Settings."
    }
    var whisperVariantPicker: String { useChinese ? "Whisper 模型" : "Whisper model" }
    var whisperVariantHint: String {
        useChinese
            ? "仅首次将模型文件下载到本机时走网络（体积可能较大，请留意进度）。转写在本机离线完成，录音不会上传。"
            : "Only the first-time download of model files uses the network (may be large—watch progress). Transcription runs offline on your Mac; recordings are never uploaded."
    }
    func speechModelsIntro(cacheRootPath: String) -> String {
        let def = WhisperModelCatalog.default
        let defMB = WhisperModelCatalog.approximateDownloadMB(for: def)
        if useChinese {
            return "1. 模型会下载到你的 Mac，语音转文字完全在本机完成，录音不会上传到服务器。\n\n2. 模型从 Hugging Face（huggingface.co）官方下载；下载完成后点「使用」即可载入并用于转写。\n\n3. 模型下载路径：\(cacheRootPath)（资源库 → Application Support → FlowType → huggingface）。\n\n4. 应用内置默认档位为「\(def)」（约 \(defMB) MB，不是「small」）；若磁盘与网络允许，更推荐使用 small 或更大的变体，识别效果通常更好。列表中标明的体积为约数；下载时可取消，删除后可重新下载（一般会续传已缓存部分），无单独暂停。"
        }
        return "1. Models download to your Mac; speech-to-text runs entirely on device. Audio is never uploaded.\n\n2. Files are fetched from the official Hugging Face Hub (huggingface.co). After download, tap Use to load and transcribe.\n\n3. Model download path: \(cacheRootPath) (Library → Application Support → FlowType → huggingface).\n\n4. The built-in default variant is “\(def)” (~\(defMB) MB, not “small”); for better accuracy, prefer small or larger when you can. Listed MB are approximate. Cancel downloads as needed, delete and retry to clear partial files—cached chunks usually resume. There is no pause."
    }
    /// 设置 → 语音模型：small / medium 旁的推荐标签。
    var speechModelRecommendedBadge: String { useChinese ? "推荐" : "Recommended" }
    /// 设置 → 语音模型：说明分组标题（与「通用」页一致）。
    var speechModelsAboutSectionTitle: String { useChinese ? "说明" : "About" }
    /// 设置 → 语音模型：列表分组标题。
    var speechModelsVariantsSectionTitle: String { useChinese ? "可选模型" : "Whisper variants" }
    var speechModelStatusDownloaded: String { useChinese ? "已下载" : "Downloaded" }
    var speechModelStatusNotDownloaded: String { useChinese ? "未下载" : "Not downloaded" }
    var speechModelStatusInUse: String { useChinese ? "使用中" : "In use" }
    var speechModelStatusLoading: String { useChinese ? "载入中…" : "Loading…" }
    var speechModelDownload: String { useChinese ? "下载" : "Download" }
    var speechModelUse: String { useChinese ? "使用" : "Use" }
    var speechModelPrefetching: String { useChinese ? "正在下载…" : "Downloading…" }
    var speechModelCancelDownload: String { useChinese ? "取消" : "Cancel" }
    /// 下载行下方：解释为何没有「暂停」按钮。
    var speechModelDownloadNoPauseFootnote: String {
        useChinese
            ? "下载过程无法暂停，只能取消；取消后再次点「下载」，通常会从已缓存内容续传。"
            : "Downloads can’t be paused—only canceled. After canceling, tap Download again; the Hub cache usually resumes."
    }
    var speechModelDelete: String { useChinese ? "删除" : "Delete" }
    var speechModelDeleteConfirmTitle: String { useChinese ? "删除本地模型？" : "Delete downloaded model?" }
    func speechModelDeleteConfirmBody(variant: String) -> String {
        useChinese
            ? "将删除变体「\(variant)」在本机 huggingface 缓存中的相关文件（含未完成下载残留）。若正在使用该变体，需重新下载或选用其它变体。"
            : "This removes cached files for “\(variant)” (including partial downloads). If it was in use, download it again or pick another variant."
    }
    func speechModelDownloadPercent(_ fraction: Double) -> String {
        let p = max(0, min(100, Int((fraction * 100).rounded(.down))))
        return useChinese ? "已下载 \(p)%" : "\(p)% complete"
    }
    func speechModelDownloadSpeedLabel(bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond, b >= 1 else {
            return useChinese ? "速度：—" : "Speed: —"
        }
        let mbps = b / 1_048_576
        if mbps >= 1 {
            return useChinese
                ? String(format: "速度：%.1f MB/s", mbps)
                : String(format: "Speed: %.1f MB/s", mbps)
        }
        let kbps = b / 1024
        return useChinese
            ? String(format: "速度：%.0f KB/s", kbps)
            : String(format: "Speed: %.0f KB/s", kbps)
    }
    func speechModelApproxMB(_ mb: Int) -> String {
        useChinese ? "约 \(mb) MB" : "~\(mb) MB"
    }

    var outputModesTab: String { useChinese ? "输出模式" : "Output Modes" }
    var outputModesIntro: String {
        useChinese
            ? "原理：语音转写完成后，要么直接粘贴原文，要么把转写稿交给大模型、用「系统提示词」规定怎么改——每一种做法就是一个输出模式。你可按需新增模式、改名称和提示词，搭出自己常用的润色或整理方式；预置几条只是常见示例。第一项「原文」固定不经过大模型，且不可改名或删除。菜单栏「输出模式」与左侧「使用」一致。"
            : "How it works: after transcription, FlowType either pastes the transcript as-is or sends it to your LLM with a system prompt that defines how to rewrite it—each setup is one output mode. Add modes, rename them, and edit prompts anytime to match your workflow; built-ins are just examples. The first mode (Raw) never calls the LLM and can’t be renamed or removed. The menu bar matches the mode marked Use."
    }
    var outputModesListTitle: String { useChinese ? "模式列表" : "Modes" }
    var outputModesListFootnote: String {
        useChinese
            ? "点选一行在右侧编辑提示词；「使用」与菜单栏当前输出模式一致。"
            : "Select a row to edit its prompt on the right. Use marks the active output mode (same as the menu bar)."
    }
    var outputModesSelectOnLeft: String { useChinese ? "请在左侧选择一个模式。" : "Select a mode in the list on the left." }
    var outputModesAdd: String { useChinese ? "新增模式" : "Add mode" }
    var outputModesDelete: String { useChinese ? "删除" : "Delete" }
    var outputModesNameLabel: String { useChinese ? "模式名称" : "Mode name" }
    var outputModesPromptLabel: String { useChinese ? "系统提示词" : "System prompt" }
    var outputModesRawHint: String {
        useChinese
            ? "此模式不调用大模型，直接将 Whisper 转写结果粘贴到目标应用。"
            : "This mode skips the LLM and pastes the Whisper transcript as-is."
    }
    var outputModesNewDefaultTitle: String { useChinese ? "新模式" : "New mode" }
    /// 系统提示词为空时，编辑器内灰色引导（开始输入即消失）。
    var outputModesPromptPlaceholder: String {
        useChinese
            ? "在这里写系统提示词，告诉大模型怎么改转写稿。例如：「去掉嗯啊口头禅，整理成一段可以直接发微信的口语消息，别加小标题。」"
            : "Describe how the model should rewrite the transcript. Example: “Remove filler words like ‘um’ and turn it into one casual chat message—no bullet lists or headings.”"
    }
    /// 提示词为空时的简短提醒（仍显示在输入框下方）。
    var outputModesPromptEmptyHint: String {
        useChinese
            ? "若留空，使用该模式润色时会提示先填写系统提示词。"
            : "If left empty, polish will ask you to fill in the system prompt first."
    }

    var openRouterChatModel: String { useChinese ? "润色所用模型" : "Polish model" }
    var openRouterRefreshModels: String { useChinese ? "测试连接并加载免费模型" : "Test & load free models" }
    var openRouterRefreshHint: String {
        useChinese
            ? "每次点击都会实时请求 OpenRouter 的最新列表（无本地缓存）。名单随官方免费政策变化；若某模型（如旧的 Llama 3 70B）不再免费，就不会出现在筛选结果里。"
            : "Each click fetches the latest list from OpenRouter (no local cache). The lineup changes with OpenRouter’s free tier; models that are no longer free (e.g. older Llama 3 70B) will not appear."
    }
    var downloadProgress: String { useChinese ? "下载进度" : "Download progress" }
    var loadProgress: String { useChinese ? "加载进度" : "Load progress" }
}
