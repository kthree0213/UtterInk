import Foundation
import UtterInkCore

package enum UserDefaultsSettingsStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidMap
    case legacyInaccessible
    case corruptStoredSettings
    case invalidSettings
    case verificationFailed

    package var description: String {
        switch self {
        case .invalidMap: "invalid legacy settings authority"
        case .legacyInaccessible: "legacy settings are inaccessible"
        case .corruptStoredSettings: "stored settings are corrupt"
        case .invalidSettings: "settings are invalid"
        case .verificationFailed: "settings verification failed"
        }
    }
}

public actor UserDefaultsSettingsStore: SettingsStore {
    package static let storageKey = "utterink.user-settings.v1"
    private static let storageVersion = 4

    private let defaults: UserDefaults
    private let legacy: any LegacyDefaultsAccess

    public init(defaults: UserDefaults, legacyMap: LegacyDefaultsMap = .bundled) throws {
        let domain = try Self.legacyDomain(from: legacyMap)
        self.defaults = defaults
        self.legacy = try LegacyDefaultsReader(suiteName: domain)
    }

    package init(
        defaults: UserDefaults,
        legacy: any LegacyDefaultsAccess,
        legacyMap: LegacyDefaultsMap = .bundled
    ) throws {
        _ = try Self.legacyDomain(from: legacyMap)
        self.defaults = defaults
        self.legacy = legacy
    }

    public func current() async throws -> UserSettings {
        try loadCurrent()
    }

    public func save(_ settings: UserSettings) async throws {
        try persist(settings)
    }

    public func update(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async throws -> UserSettings {
        var value = try loadCurrent()
        mutation(&value)
        try persist(value)
        return value
    }

    private func loadCurrent() throws -> UserSettings {
        if let object = defaults.object(forKey: Self.storageKey) {
            guard let stored = object as? Data else {
                throw UserDefaultsSettingsStoreError.corruptStoredSettings
            }
            let decoded = try decodeStored(stored)
            if decoded.requiresRewrite {
                try persist(decoded.settings)
            }
            return decoded.settings
        }

        let migrated: UserSettings
        do {
            migrated = try migrateLegacy()
        } catch let error as UserDefaultsSettingsStoreError {
            throw error
        } catch {
            throw UserDefaultsSettingsStoreError.legacyInaccessible
        }
        try persist(migrated)
        return migrated
    }

    private func persist(_ settings: UserSettings) throws {
        guard Self.isValid(settings) else {
            throw UserDefaultsSettingsStoreError.invalidSettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded: Data
        do {
            encoded = try encoder.encode(StoredSettings(version: Self.storageVersion, settings: settings))
        } catch {
            throw UserDefaultsSettingsStoreError.invalidSettings
        }

        defaults.set(encoded, forKey: Self.storageKey)
        guard let readback = defaults.data(forKey: Self.storageKey), readback == encoded else {
            throw UserDefaultsSettingsStoreError.verificationFailed
        }
        let verified = try decodeStored(readback)
        guard !verified.requiresRewrite, verified.settings == settings else {
            throw UserDefaultsSettingsStoreError.verificationFailed
        }
    }

    private func decodeStored(_ data: Data) throws -> DecodedStoredSettings {
        do {
            let envelope = try JSONDecoder().decode(StoredSettings.self, from: data)
            guard Self.isValid(envelope.settings) else {
                throw UserDefaultsSettingsStoreError.corruptStoredSettings
            }
            switch envelope.version {
            case Self.storageVersion:
                return DecodedStoredSettings(
                    settings: envelope.settings,
                    requiresRewrite: false
                )
            case 3:
                let upgraded = Self.upgradingVersionThreePresets(envelope.settings)
                guard Self.isValid(upgraded) else {
                    throw UserDefaultsSettingsStoreError.corruptStoredSettings
                }
                return DecodedStoredSettings(
                    settings: upgraded,
                    requiresRewrite: true
                )
            case 2:
                let upgraded = Self.upgradingVersionTwoPresets(envelope.settings)
                guard Self.isValid(upgraded) else {
                    throw UserDefaultsSettingsStoreError.corruptStoredSettings
                }
                return DecodedStoredSettings(
                    settings: upgraded,
                    requiresRewrite: true
                )
            case 1:
                var upgraded = envelope.settings
                upgraded = Self.replacingRetiredNaturalChat(in: upgraded)
                upgraded.outputModes = Self.appendingMissingPresetModes(
                    to: upgraded.outputModes
                )
                guard Self.isValid(upgraded) else {
                    throw UserDefaultsSettingsStoreError.corruptStoredSettings
                }
                return DecodedStoredSettings(
                    settings: upgraded,
                    requiresRewrite: true
                )
            default:
                throw UserDefaultsSettingsStoreError.corruptStoredSettings
            }
        } catch let error as UserDefaultsSettingsStoreError {
            throw error
        } catch {
            throw UserDefaultsSettingsStoreError.corruptStoredSettings
        }
    }

    private func migrateLegacy() throws -> UserSettings {
        guard let domain = try legacy.persistentDomain() else {
            return .p0Default
        }

        var result = UserSettings.p0Default
        let migratedProfiles = migrateProfiles(domain)
        result.providerProfiles = migratedProfiles
        result.selectedProviderProfileID = selectedUUID(
            domain["llmActiveProviderProfileId"],
            allowed: Set(migratedProfiles.map(\.id))
        )

        let migratedModes = migrateOutputModes(domain)
        result.outputModes = migratedModes.modes
        result.selectedOutputModeID = selectedOutputMode(
            domain["activeOutputModeProfileId"],
            modes: migratedModes.modes,
            legacyRawIDs: migratedModes.legacyRawIDs
        )

        if let model = nonblankString(domain["whisperKitModelId"]) {
            result.speechModelID = model
        }
        result.recognition = migrateRecognition(domain) ?? result.recognition

        if let shortcut = nonblankString(domain["shortcutMode"]) {
            switch shortcut {
            case "pushToTalk", "holdToTalk": result.shortcutMode = .holdToTalk
            case "toggle": result.shortcutMode = .toggle
            default: break
            }
        }

        if let value = boolValue(domain["launchAtLogin"]) { result.launchAtLogin = value }
        if let value = boolValue(domain["showFloatingRecorder"]) { result.showFloatingRecorder = value }
        if let value = boolValue(domain["historyEnabled"]) { result.historyEnabled = value }
        if let raw = nonblankString(domain["deliveryPreference"]),
           let preference = DeliveryPreference(rawValue: raw) {
            result.deliveryPreference = preference
        }
        if let value = boolValue(domain["onboardingCompletedV2"]) {
            result.onboardingCompletedV2 = value
        }
        if let step = integerValue(domain["onboardingStep"]), step >= 0 {
            result.onboardingStep = step
        }

        guard Self.isValid(result) else {
            throw UserDefaultsSettingsStoreError.invalidSettings
        }
        return result
    }

    private func migrateProfiles(_ domain: [String: Any]) -> [ProviderProfile] {
        let source = domain["llmProviderProfilesV1"]
        let identifierOccurrences = legacyUUIDOccurrences(source)
        let decoded: [LegacyProviderSettings] = decodeLegacyArray(source)
        var seen = Set<UUID>()
        var result: [ProviderProfile] = []

        for legacyProfile in decoded
        where identifierOccurrences[legacyProfile.id] == 1 && seen.insert(legacyProfile.id).inserted {
            guard let endpoint = endpoint(for: legacyProfile) else { continue }
            let title = nonblankString(legacyProfile.title) ?? displayName(for: legacyProfile.template)
            let modelKey = "llmP.\(legacyProfile.id.uuidString).modelId"
            let model = nonblankString(domain[modelKey]) ?? defaultModel(for: legacyProfile.template)
            guard let model, !title.isEmpty else { continue }
            result.append(
                ProviderProfile(
                    id: legacyProfile.id,
                    title: title,
                    baseURL: endpoint.url,
                    modelID: model,
                    policy: endpoint.policy
                )
            )
        }
        return result
    }

    private func endpoint(for profile: LegacyProviderSettings) -> (url: URL, policy: EndpointPolicy)? {
        let value: String
        if profile.template == "custom" {
            guard let custom = nonblankString(profile.customOpenAIBaseURL) else { return nil }
            value = custom
        } else {
            guard let fixed = Self.fixedEndpoints[profile.template] else { return nil }
            value = fixed
        }
        guard let components = URLComponents(string: value),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host,
              !rawHost.isEmpty,
              let url = components.url
        else { return nil }
        if scheme == "https" { return (url, .remoteHTTPS) }
        if scheme == "http",
           let host = Self.canonicalLoopbackHost(rawHost),
           Self.isLoopback(host) {
            return (url, .loopbackHTTP)
        }
        return nil
    }

    private func migrateOutputModes(_ domain: [String: Any]) -> (modes: [OutputMode], legacyRawIDs: Set<UUID>) {
        let decoded: [LegacyOutputModeSettings] = decodeLegacyArray(domain["outputModeProfilesV1"])
        var modes = OutputMode.defaultModes
        var seen = Set(modes.map(\.id))
        var legacyRawIDs: Set<UUID> = [OutputMode.rawID]

        for legacyMode in decoded {
            if legacyMode.skipsLLM {
                legacyRawIDs.insert(legacyMode.id)
                continue
            }
            guard seen.insert(legacyMode.id).inserted,
                  let title = nonblankString(legacyMode.title),
                  let instructions = nonblankString(legacyMode.systemPrompt)
            else { continue }
            modes.append(
                OutputMode(
                    id: legacyMode.id,
                    title: title,
                    skipsPolishing: false,
                    instructions: instructions
                )
            )
        }
        return (modes, legacyRawIDs)
    }

    private static func appendingMissingPresetModes(to modes: [OutputMode]) -> [OutputMode] {
        var result = modes
        var seen = Set(modes.map(\.id))
        for preset in OutputMode.defaultPolishModes where seen.insert(preset.id).inserted {
            result.append(preset)
        }
        return result
    }

    private static func upgradingVersionTwoPresets(_ settings: UserSettings) -> UserSettings {
        var upgraded = replacingRetiredNaturalChat(in: settings)
        guard !upgraded.outputModes.contains(where: {
            $0.id == OutputMode.translateToEnglishID
        }) else { return upgraded }
        upgraded.outputModes.append(.translateToEnglish)
        return upgraded
    }

    private static func upgradingVersionThreePresets(_ settings: UserSettings) -> UserSettings {
        var upgraded = replacingRetiredTranslateToChinese(in: settings)
        guard !upgraded.outputModes.contains(where: {
            $0.id == OutputMode.translateToEnglishID
        }) else { return upgraded }
        upgraded.outputModes.append(.translateToEnglish)
        return upgraded
    }

    private static func replacingRetiredNaturalChat(in settings: UserSettings) -> UserSettings {
        var upgraded = settings
        guard let retiredIndex = upgraded.outputModes.firstIndex(where: {
            $0.id == OutputMode.retiredNaturalChatID
        }), upgraded.outputModes[retiredIndex] == .retiredNaturalChat else {
            return upgraded
        }

        if upgraded.outputModes.contains(where: { $0.id == OutputMode.translateToEnglishID }) {
            upgraded.outputModes.remove(at: retiredIndex)
        } else {
            upgraded.outputModes[retiredIndex] = .translateToEnglish
        }
        if upgraded.selectedOutputModeID == OutputMode.retiredNaturalChatID {
            upgraded.selectedOutputModeID = OutputMode.translateToEnglishID
        }
        return upgraded
    }

    private static func replacingRetiredTranslateToChinese(in settings: UserSettings) -> UserSettings {
        var upgraded = settings
        guard let retiredIndex = upgraded.outputModes.firstIndex(where: {
            $0.id == OutputMode.retiredTranslateToChineseID
        }), upgraded.outputModes[retiredIndex] == .retiredTranslateToChinese else {
            return upgraded
        }

        if upgraded.outputModes.contains(where: { $0.id == OutputMode.translateToEnglishID }) {
            upgraded.outputModes.remove(at: retiredIndex)
        } else {
            upgraded.outputModes[retiredIndex] = .translateToEnglish
        }
        if upgraded.selectedOutputModeID == OutputMode.retiredTranslateToChineseID {
            upgraded.selectedOutputModeID = OutputMode.translateToEnglishID
        }
        return upgraded
    }

    private func migrateRecognition(_ domain: [String: Any]) -> RecognitionConfiguration? {
        if let automatic = boolValue(domain["speechTranscriptionAutoDetectLanguage"]) {
            if automatic { return .automatic }
            if let language = nonblankString(domain["speechTranscriptionLanguageCode"]) {
                return .fixed(languageCode: language)
            }
            return nil
        }
        if let language = nonblankString(domain["speechTranscriptionLanguageCode"]) {
            return .fixed(languageCode: language)
        }
        if let legacy = nonblankString(domain["speechPrimaryLanguage"]), legacy == "en" || legacy == "zh" {
            return .fixed(languageCode: legacy)
        }
        return nil
    }

    private func selectedOutputMode(
        _ value: Any?,
        modes: [OutputMode],
        legacyRawIDs: Set<UUID>
    ) -> UUID {
        guard let string = value as? String, let id = UUID(uuidString: string) else {
            return OutputMode.rawID
        }
        if legacyRawIDs.contains(id) { return OutputMode.rawID }
        return modes.contains(where: { $0.id == id }) ? id : OutputMode.rawID
    }

    private func selectedUUID(_ value: Any?, allowed: Set<UUID>) -> UUID? {
        guard let string = value as? String, let id = UUID(uuidString: string), allowed.contains(id) else {
            return nil
        }
        return id
    }

    private func decodeLegacyArray<T: Decodable>(_ value: Any?) -> [T] {
        legacyJSONArray(value).compactMap { element in
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? JSONDecoder().decode(T.self, from: elementData)
            else { return nil }
            return decoded
        }
    }

    private func legacyUUIDOccurrences(_ value: Any?) -> [UUID: Int] {
        var occurrences: [UUID: Int] = [:]
        for case let element as [String: Any] in legacyJSONArray(value) {
            guard let rawID = element["id"] as? String,
                  let id = UUID(uuidString: rawID)
            else { continue }
            occurrences[id, default: 0] += 1
        }
        return occurrences
    }

    private func legacyJSONArray(_ value: Any?) -> [Any] {
        let data: Data
        if let stored = value as? Data {
            data = stored
        } else if let string = value as? String {
            data = Data(string.utf8)
        } else {
            return []
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return array
    }

    private func nonblankString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boolValue(_ value: Any?) -> Bool? {
        value as? Bool
    }

    private func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private func displayName(for template: String) -> String {
        Self.displayNames[template] ?? "Provider"
    }

    private func defaultModel(for template: String) -> String? {
        Self.defaultModels[template]
    }

    private static func legacyDomain(from map: LegacyDefaultsMap) throws -> String {
        let domains = Set(map.entries.map(\.legacyDomain))
        guard map.entries.count == 4,
              domains == ["dev.flowtype.FlowType"],
              !map.authorityHash.isEmpty,
              !map.supportEvidenceHashes.isEmpty
        else {
            throw UserDefaultsSettingsStoreError.invalidMap
        }
        return "dev.flowtype.FlowType"
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".")
        guard octets.count == 4, let first = Int(octets[0]), first == 127 else { return false }
        return octets.allSatisfy { component in
            guard let value = Int(component) else { return false }
            return (0...255).contains(value) && String(value) == component
        }
    }

    private static func isValid(_ settings: UserSettings) -> Bool {
        guard settings.onboardingStep >= 0,
              settings.outputModes.first == .raw,
              settings.outputModes.filter({ $0.id == OutputMode.rawID }) == [.raw],
              Set(settings.outputModes.map(\.id)).count == settings.outputModes.count,
              settings.outputModes.contains(where: { $0.id == settings.selectedOutputModeID }),
              Set(settings.providerProfiles.map(\.id)).count == settings.providerProfiles.count,
              settings.providerProfiles.allSatisfy(isValidProviderEndpoint)
        else { return false }
        if let selected = settings.selectedProviderProfileID,
           !settings.providerProfiles.contains(where: { $0.id == selected }) {
            return false
        }
        return settings.providerProfiles.allSatisfy {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func isValidProviderEndpoint(_ profile: ProviderProfile) -> Bool {
        guard let components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host,
              !rawHost.isEmpty
        else { return false }

        switch profile.policy {
        case .remoteHTTPS:
            return scheme == "https"
        case .loopbackHTTP:
            guard scheme == "http", let host = canonicalLoopbackHost(rawHost) else { return false }
            return isLoopback(host)
        }
    }

    private static func canonicalLoopbackHost(_ rawHost: String) -> String? {
        if rawHost == "[::1]" { return "::1" }
        let lowered = rawHost.lowercased()
        return rawHost == lowered ? lowered : nil
    }

    private static let fixedEndpoints: [String: String] = [
        "openrouter": "https://openrouter.ai/api/v1",
        "openai": "https://api.openai.com/v1",
        "groq": "https://api.groq.com/openai/v1",
        "together": "https://api.together.xyz/v1",
        "minimax": "https://api.minimaxi.com/v1",
        "minimax_global": "https://api.minimax.io/v1",
        "deepseek": "https://api.deepseek.com/v1",
        "moonshot": "https://api.moonshot.cn/v1",
        "siliconflow": "https://api.siliconflow.cn/v1",
        "alibaba_qwen": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "zhipu_glm": "https://open.bigmodel.cn/api/paas/v4",
        "google_gemini": "https://generativelanguage.googleapis.com/v1beta/openai",
        "volcano_ark": "https://ark.cn-beijing.volces.com/api/v3"
    ]

    private static let defaultModels: [String: String] = [
        "openrouter": "openrouter/free",
        "openai": "gpt-4o-mini",
        "groq": "llama-3.3-70b-versatile",
        "together": "meta-llama/Llama-3.1-8B-Instruct-Turbo",
        "minimax": "MiniMax-M2.7",
        "minimax_global": "MiniMax-M2.7",
        "deepseek": "deepseek-chat",
        "moonshot": "moonshot-v1-8k",
        "siliconflow": "Qwen/Qwen2.5-7B-Instruct",
        "alibaba_qwen": "qwen-turbo",
        "zhipu_glm": "glm-4-flash",
        "google_gemini": "gemini-2.0-flash",
        "volcano_ark": "doubao-pro-32k",
        "custom": "default"
    ]

    private static let displayNames: [String: String] = [
        "openrouter": "OpenRouter",
        "openai": "OpenAI",
        "groq": "Groq",
        "together": "Together AI",
        "minimax": "MiniMax",
        "minimax_global": "MiniMax Global",
        "deepseek": "DeepSeek",
        "moonshot": "Moonshot",
        "siliconflow": "SiliconFlow",
        "alibaba_qwen": "Alibaba Qwen",
        "zhipu_glm": "Zhipu GLM",
        "google_gemini": "Google Gemini",
        "volcano_ark": "Volcano Ark",
        "custom": "Custom"
    ]
}

private struct StoredSettings: Codable {
    let version: Int
    let settings: UserSettings
}

private struct DecodedStoredSettings {
    let settings: UserSettings
    let requiresRewrite: Bool
}

private struct LegacyProviderSettings: Decodable {
    let id: UUID
    let title: String
    let template: String
    let customOpenAIBaseURL: String?
}

private struct LegacyOutputModeSettings: Decodable {
    let id: UUID
    let title: String
    let skipsLLM: Bool
    let systemPrompt: String
}
