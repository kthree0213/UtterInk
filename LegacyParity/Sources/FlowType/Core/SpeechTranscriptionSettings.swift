import Foundation

/// 语音转写语种偏好（`UserDefaults`），供 Whisper `DecodingOptions` 使用。
enum SpeechTranscriptionSettings {
    /// Whisper 语言码，如 `zh`、`en`、`ja`（与 OpenAI Whisper 一致，共数十种，见 `WhisperTranscriptionLanguageCatalog`）。
    static let languageCodeKey = "speechTranscriptionLanguageCode"
    /// 为 `true` 时传 `language: nil` 且 `detectLanguage: true`，由模型自动判断语种。
    static let autoDetectKey = "speechTranscriptionAutoDetectLanguage"

    private static let legacyPrimaryKey = "speechPrimaryLanguage"

    static let defaultLanguageCode = "zh"
    static let defaultAutoDetect = false

    /// 从旧版 `speechPrimaryLanguage`（仅 zh/en）迁移；应在首次使用转写或读取菜单前调用。
    static func migrateUserDefaultsIfNeeded() {
        let d = UserDefaults.standard
        if d.object(forKey: languageCodeKey) == nil {
            let legacy = d.string(forKey: legacyPrimaryKey)
            let code = (legacy == "en") ? "en" : "zh"
            d.set(code, forKey: languageCodeKey)
        }
        if d.object(forKey: autoDetectKey) == nil {
            d.set(false, forKey: autoDetectKey)
        }
    }

    /// 设置「通用」与菜单栏共用的分组内 Picker 标题。
    static func userFacingLabel(useChinese: Bool) -> String {
        useChinese ? "优先识别语种" : "Primary language"
    }

    /// 说明：优先提示 Whisper，减少误判；下接语言码列表与粤语等注意事项。
    static func userFacingExplanation(useChinese: Bool) -> String {
        useChinese
            ? "并非限制你只能说所选语言，而是告诉 Whisper 优先按该语种识别，从而减少听成另一种语言之类的误判。下拉里每一种语言码都与 Whisper 多语种模型一致（与 WhisperKit / OpenAI 开源 whisper 的 tokenizer 列表同源，约数十种）。列入列表只表示模型具备该语种 token，并不保证每种话都能听得很准——粤语代码「yue」虽在表中，实际效果往往弱于普通话「zh」，说粤语时可先试「zh」或开启下方「自动识别语种」。若仍不理想，可到「语音模型」换更大变体。"
            : "This doesn’t restrict you to one spoken language—it tells Whisper to favor that language when decoding, which reduces wrong-language mishears. Every code in the menu matches Whisper’s multilingual vocabulary (same set as WhisperKit and OpenAI’s open-source whisper `tokenizer.py`, dozens of languages). Being listed means the model has that language token—not that accuracy is equally strong for all. Cantonese (`yue`) is often weaker than Mandarin (`zh`); for Yue speech try `zh` or turn on auto-detect below. If quality is still off, try a larger variant under Speech Model."
    }
}
