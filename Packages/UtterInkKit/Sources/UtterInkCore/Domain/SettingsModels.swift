import Foundation

public enum RecognitionConfiguration: Equatable, Codable, Sendable {
    case fixed(languageCode: String)
    case automatic
}

public struct OutputMode: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var skipsPolishing: Bool
    public var instructions: String

    public init(id: UUID, title: String, skipsPolishing: Bool, instructions: String) {
        self.id = id
        self.title = title
        self.skipsPolishing = skipsPolishing
        self.instructions = instructions
    }

    public static let rawID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let raw = OutputMode(id: rawID, title: "Raw", skipsPolishing: true, instructions: "")

    public static let cleanUpID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    public static let aiPromptID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    public static let workMessageID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    public static let classicalChineseID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    public static let translateToEnglishID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!

    package static let retiredNaturalChatID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    package static let retiredTranslateToChineseID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!

    public static let cleanUp = OutputMode(
        id: cleanUpID,
        title: "Clean Up",
        skipsPolishing: false,
        instructions: "Polish the transcript without changing its meaning. Remove filler words, repetitions, and false starts; fix punctuation, grammar, and obvious speech-recognition errors. Preserve the original language, tone, names, numbers, terminology, uncertainty, and intent. Do not summarize, add information, answer questions, or explain your edits. Return only the finished text."
    )

    public static let aiPrompt = OutputMode(
        id: aiPromptID,
        title: "AI Prompt",
        skipsPolishing: false,
        instructions: "Convert the transcript into a clear, directly usable prompt for an AI system. Preserve every explicit goal, constraint, name, number, example, reference, and requested output. Remove filler words and repetition, and organize the content into a logical instruction. Use sections or bullet points only when they improve clarity. Do not answer the prompt, invent missing requirements, or add commentary. Return only the finished prompt in the transcript's language."
    )

    public static let workMessage = OutputMode(
        id: workMessageID,
        title: "Work Message",
        skipsPolishing: false,
        instructions: "Rewrite the transcript as a clear, concise, and professional work message. Preserve all facts, names, numbers, dates, deadlines, uncertainty, and commitments. Improve structure, grammar, and tone; be polite but not stiff. Do not add a subject line, greeting, sign-off, new commitments, or information that was not spoken. Return only the finished message in the original language."
    )

    public static let classicalChinese = OutputMode(
        id: classicalChineseID,
        title: "Classical Chinese",
        skipsPolishing: false,
        instructions: "Rewrite the transcript as concise and readable Classical Chinese (文言文). Preserve the original meaning, people, names, numbers, dates, facts, and emotional tone. You may adjust word order and diction, but do not invent allusions, add information, or pile up obscure characters. Keep modern proper nouns unchanged when necessary. Do not include explanations, annotations, or a modern-language translation. Return only the rewritten Classical Chinese text."
    )

    public static let translateToEnglish = OutputMode(
        id: translateToEnglishID,
        title: "Translate to English",
        skipsPolishing: false,
        instructions: "Translate the transcript into natural English. Preserve its full meaning, tone, names, numbers, dates, technical terms, formatting, and uncertainty. Do not summarize, answer questions, add information, or include explanations, labels, or quotation marks. If the transcript is already English, preserve its wording and only fix obvious transcription, grammar, or punctuation errors. Return only the final English text."
    )

    package static let retiredTranslateToChinese = OutputMode(
        id: retiredTranslateToChineseID,
        title: "Translate to Chinese",
        skipsPolishing: false,
        instructions: "Translate the transcript into natural Simplified Chinese. Preserve its full meaning, tone, names, numbers, dates, technical terms, formatting, and uncertainty. Do not summarize, answer questions, add information, or include explanations, labels, or quotation marks. If the transcript is already Chinese, preserve its wording and only fix obvious transcription or punctuation errors. Return only the final Chinese text."
    )

    package static let retiredNaturalChat = OutputMode(
        id: retiredNaturalChatID,
        title: "Natural Chat",
        skipsPolishing: false,
        instructions: "Rewrite the transcript as a natural message for everyday chat. Preserve the original meaning, emotion, level of politeness, and personal voice. Remove filler words and repetition, fix punctuation, and prefer concise conversational phrasing. Do not make it sound like a formal email, and do not add greetings, emojis, opinions, or details that were not spoken. Return only the finished message in the original language."
    )

    public static let defaultPolishModes: [OutputMode] = [
        cleanUp,
        aiPrompt,
        translateToEnglish,
        workMessage,
        classicalChinese,
    ]

    public static let defaultModes: [OutputMode] = [.raw] + defaultPolishModes

    public var requiresProvider: Bool {
        !skipsPolishing
    }

    public var presetSummary: String? {
        if self == Self.cleanUp { return "Tidy speech without changing your meaning." }
        if self == Self.aiPrompt { return "Turn speech into a ready-to-use AI prompt." }
        if self == Self.translateToEnglish {
            return "Translate speech directly into natural English."
        }
        if self == Self.workMessage { return "Make work messages clear and professional." }
        if self == Self.classicalChinese {
            return "Rewrite your words as readable Classical Chinese."
        }
        return nil
    }
}

public enum EndpointPolicy: String, Codable, Sendable {
    case remoteHTTPS, loopbackHTTP
}

public struct ProviderSelection: Equatable, Sendable {
    public let profileID: UUID
    public let baseURL: URL
    public let modelID: String
    public let policy: EndpointPolicy

    public init(profileID: UUID, baseURL: URL, modelID: String, policy: EndpointPolicy) {
        self.profileID = profileID
        self.baseURL = baseURL
        self.modelID = modelID
        self.policy = policy
    }
}

public struct ProviderProfile: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var baseURL: URL
    public var modelID: String
    public var policy: EndpointPolicy

    public init(id: UUID, title: String, baseURL: URL, modelID: String, policy: EndpointPolicy) {
        self.id = id
        self.title = title
        self.baseURL = baseURL
        self.modelID = modelID
        self.policy = policy
    }
}

public struct DeliveryTargetID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum DeliveryTarget: Equatable, Sendable {
    case external(DeliveryTargetID)
    case onboardingTest
    case copyOnly
}

public enum DeliveryPreference: String, Codable, Sendable {
    case automaticPaste, copyOnly
}

public enum ShortcutMode: String, Codable, Sendable {
    case toggle, holdToTalk
}

public struct UserSettings: Equatable, Codable, Sendable {
    public var launchAtLogin: Bool
    public var showFloatingRecorder: Bool
    public var recognition: RecognitionConfiguration
    public var speechModelID: String
    public var outputModes: [OutputMode]
    public var selectedOutputModeID: UUID
    public var providerProfiles: [ProviderProfile]
    public var selectedProviderProfileID: UUID?
    public var shortcutMode: ShortcutMode
    public var historyEnabled: Bool
    public var deliveryPreference: DeliveryPreference
    public var onboardingCompletedV2: Bool
    public var onboardingStep: Int

    public init(
        launchAtLogin: Bool,
        showFloatingRecorder: Bool,
        recognition: RecognitionConfiguration,
        speechModelID: String,
        outputModes: [OutputMode],
        selectedOutputModeID: UUID,
        providerProfiles: [ProviderProfile],
        selectedProviderProfileID: UUID?,
        shortcutMode: ShortcutMode,
        historyEnabled: Bool,
        deliveryPreference: DeliveryPreference,
        onboardingCompletedV2: Bool,
        onboardingStep: Int
    ) {
        self.launchAtLogin = launchAtLogin
        self.showFloatingRecorder = showFloatingRecorder
        self.recognition = recognition
        self.speechModelID = speechModelID
        self.outputModes = outputModes
        self.selectedOutputModeID = selectedOutputModeID
        self.providerProfiles = providerProfiles
        self.selectedProviderProfileID = selectedProviderProfileID
        self.shortcutMode = shortcutMode
        self.historyEnabled = historyEnabled
        self.deliveryPreference = deliveryPreference
        self.onboardingCompletedV2 = onboardingCompletedV2
        self.onboardingStep = onboardingStep
    }

    public static let p0Default = UserSettings(
        launchAtLogin: false, showFloatingRecorder: true, recognition: .automatic,
        speechModelID: "small", outputModes: OutputMode.defaultModes, selectedOutputModeID: OutputMode.rawID,
        providerProfiles: [], selectedProviderProfileID: nil, shortcutMode: .toggle,
        historyEnabled: true, deliveryPreference: .automaticPaste,
        onboardingCompletedV2: false, onboardingStep: 0
    )
}
