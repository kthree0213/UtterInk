import Foundation

/// 与 WhisperKit / `openai_whisper-*` 变体名一致（见 `ModelVariant.description`）。
enum WhisperModelCatalog {
    static let storageKey = "whisperKitModelId"
    /// 首次安装/未写入偏好时的默认变体（较轻量）；列表中对 small、medium 展示「推荐」以引导升级。
    static let `default` = "base"

    static let allVariantIDs: [String] = [
        "tiny", "tiny.en",
        "base", "base.en",
        "small", "small.en",
        "medium", "medium.en",
        "large", "large-v2", "large-v3"
    ]

    /// 下载体积参考值（MB）。含 `_216MB` 等后缀的条目取自 Hugging Face `argmaxinc/whisperkit-coreml` 目录命名；其余为常见 Core ML 包量级，实际以下载为准。
    static func approximateDownloadMB(for variant: String) -> Int {
        approximateDownloadMBTable[variant] ?? 200
    }

    /// 是否在语音模型列表中显示「推荐」标签（兼顾质量与常见硬件）。
    static func showsQualityRecommendationBadge(for variant: String) -> Bool {
        switch variant {
        case "small", "small.en", "medium", "medium.en": true
        default: false
        }
    }

    private static let approximateDownloadMBTable: [String: Int] = [
        "tiny": 75, "tiny.en": 75,
        "base": 150, "base.en": 150,
        "small": 216, "small.en": 217,
        "medium": 1500, "medium.en": 1500,
        "large": 950, "large-v2": 949, "large-v3": 947
    ]

    static func shortDescription(for variant: String, useChinese: Bool) -> String {
        if useChinese {
            switch variant {
            case "tiny", "tiny.en":
                return "最小、最快，准确度较低；适合试玩或磁盘/内存较紧的设备。"
            case "base", "base.en":
                return "比 small 更轻、更快，准确度略低；磁盘或内存紧张时可考虑。"
            case "small", "small.en":
                return "默认推荐：准确度与体积、速度的平衡较好，适合多数日常使用。"
            case "medium", "medium.en":
                return "高准确度，下载与占用较大，适合常做长语音。"
            case "large":
                return "大型多语言模型，资源占用高。"
            case "large-v2":
                return "Large 改进版，体积与质量介于 large 与 v3 之间。"
            case "large-v3":
                return "当前系列中通常最强，体积最大、加载最慢。"
            default:
                return "OpenAI Whisper Core ML 变体。"
            }
        } else {
            switch variant {
            case "tiny", "tiny.en":
                return "Smallest/fastest; lower accuracy—good for quick tries or tight disk/RAM."
            case "base", "base.en":
                return "Lighter/faster than small; slightly lower accuracy—good if disk or RAM is tight."
            case "small", "small.en":
                return "Default pick: solid accuracy with reasonable size and speed for everyday use."
            case "medium", "medium.en":
                return "High accuracy; heavy download—good for long sessions."
            case "large":
                return "Large multilingual model; high resource use."
            case "large-v2":
                return "Improved large checkpoint; between large and v3."
            case "large-v3":
                return "Strongest listed; largest and slowest to load."
            default:
                return "OpenAI Whisper Core ML variant."
            }
        }
    }
}
