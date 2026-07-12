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
        speechModelID: "small", outputModes: [.raw], selectedOutputModeID: OutputMode.rawID,
        providerProfiles: [], selectedProviderProfileID: nil, shortcutMode: .toggle,
        historyEnabled: true, deliveryPreference: .automaticPaste,
        onboardingCompletedV2: false, onboardingStep: 0
    )
}
