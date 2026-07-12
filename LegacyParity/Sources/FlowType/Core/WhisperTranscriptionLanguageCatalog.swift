import Foundation
import WhisperKit

/// 基于 WhisperKit `Constants.languages` 的语种列表（与 OpenAI Whisper 开源 `tokenizer.py` 中的语言码一致）；展示名优先用各语言**自称**（endonym），设置与菜单栏共用同一套文案。
enum WhisperTranscriptionLanguageCatalog {
    /// 菜单栏快捷项（常见语种；不含 `yue`——粤语在模型里虽有码，固定为 yue 时效果常不如 `zh`）。
    static let menuQuickCodes: [String] = ["zh", "en", "ja", "ko", "es", "fr", "de", "pt", "ru", "it"]

    /// Whisper 语言码 → 当地常用自称（无法全覆盖时回退为英文参考名）。
    private static let endonyms: [String: String] = [
        "af": "Afrikaans",
        "am": "አማርኛ",
        "ar": "العربية",
        "as": "অসমীয়া",
        "az": "Azərbaycanca",
        "ba": "Башҡортса",
        "be": "Беларуская",
        "bg": "Български",
        "bn": "বাংলা",
        "br": "Brezhoneg",
        "bs": "Bosanski",
        "ca": "Català",
        "cs": "Čeština",
        "cy": "Cymraeg",
        "da": "Dansk",
        "de": "Deutsch",
        "el": "Ελληνικά",
        "en": "English",
        "es": "Español",
        "et": "Eesti",
        "eu": "Euskara",
        "fa": "فارسی",
        "fi": "Suomi",
        "fo": "Føroyskt",
        "fr": "Français",
        "gl": "Galego",
        "gu": "ગુજરાતી",
        "ha": "Hausa",
        "haw": "ʻŌlelo Hawaiʻi",
        "he": "עברית",
        "hi": "हिन्दी",
        "hr": "Hrvatski",
        "ht": "Kreyòl ayisyen",
        "hu": "Magyar",
        "hy": "Հայերեն",
        "id": "Bahasa Indonesia",
        "is": "Íslenska",
        "it": "Italiano",
        "ja": "日本語",
        "jw": "Basa Jawa",
        "ka": "ქართული",
        "kk": "Қазақша",
        "km": "ភាសាខ្មែរ",
        "kn": "ಕನ್ನಡ",
        "ko": "한국어",
        "la": "Latina",
        "lb": "Lëtzebuergesch",
        "ln": "Lingála",
        "lo": "ລາວ",
        "lt": "Lietuvių",
        "lv": "Latviešu",
        "mg": "Fiteny malagasy",
        "mi": "Te Reo Māori",
        "mk": "Македонски",
        "ml": "മലയാളം",
        "mn": "Монгол",
        "mr": "मराठी",
        "ms": "Bahasa Melayu",
        "mt": "Malti",
        "my": "မြန်မာဘာသာ",
        "ne": "नेपाली",
        "nl": "Nederlands",
        "nn": "Norsk nynorsk",
        "no": "Norsk",
        "oc": "Occitan",
        "pa": "ਪੰਜਾਬੀ",
        "pl": "Polski",
        "ps": "پښتو",
        "pt": "Português",
        "ro": "Română",
        "ru": "Русский",
        "sa": "संस्कृतम्",
        "sd": "سنڌي",
        "si": "සිංහල",
        "sk": "Slovenčina",
        "sl": "Slovenščina",
        "sn": "chiShona",
        "so": "Soomaali",
        "sq": "Shqip",
        "sr": "Српски",
        "su": "Basa Sunda",
        "sv": "Svenska",
        "sw": "Kiswahili",
        "ta": "தமிழ்",
        "te": "తెలుగు",
        "tg": "Тоҷикӣ",
        "th": "ไทย",
        "tk": "Türkmençe",
        "tl": "Tagalog",
        "tr": "Türkçe",
        "tt": "Татарча",
        "uk": "Українська",
        "ur": "اردو",
        "uz": "Oʻzbekcha",
        "vi": "Tiếng Việt",
        "yi": "ייִדיש",
        "yo": "Yorùbá",
        "yue": "粵語",
        "zh": "中文",
        "bo": "བོད་སྐད་"
    ]

    /// 设置页与菜单共用的展示：`自称 (码)`，便于区分同形语言与排错。
    static func displayLabel(code: String) -> String {
        "\(nativeName(for: code)) (\(code))"
    }

    /// 仅自称（菜单栏若需更短可再截断；当前与设置一致带码更清晰）。
    static func nativeName(for code: String) -> String {
        if let n = endonyms[code] { return n }
        return englishReferenceName(for: code)
    }

    /// 按**英文参考名**排序，避免中文/日文等混排时顺序难找。
    static let pickerRows: [(code: String, label: String)] = {
        var englishByCode: [String: String] = [:]
        for (name, c) in Constants.languages {
            if englishByCode[c] == nil {
                englishByCode[c] = formatEnglishStyleName(name)
            }
        }
        return englishByCode.keys.sorted { a, b in
            let la = englishByCode[a] ?? a
            let lb = englishByCode[b] ?? b
            return la.localizedCaseInsensitiveCompare(lb) == .orderedAscending
        }.map { code in
            (code: code, label: displayLabel(code: code))
        }
    }()

    private static func englishReferenceName(for code: String) -> String {
        for (name, c) in Constants.languages where c == code {
            return formatEnglishStyleName(name)
        }
        return code
    }

    private static func formatEnglishStyleName(_ raw: String) -> String {
        raw.split(separator: " ").map { part in
            let w = String(part)
            guard let f = w.first else { return w }
            return String(f).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
