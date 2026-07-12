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
    private static let storageVersion = 1

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
        if let stored = defaults.data(forKey: Self.storageKey) {
            return try decodeStored(stored)
        }

        let migrated: UserSettings
        do {
            migrated = try migrateLegacy()
        } catch let error as UserDefaultsSettingsStoreError {
            throw error
        } catch {
            throw UserDefaultsSettingsStoreError.legacyInaccessible
        }
        try await save(migrated)
        return migrated
    }

    public func save(_ settings: UserSettings) async throws {
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
        guard verified == settings else {
            throw UserDefaultsSettingsStoreError.verificationFailed
        }
    }

    private func decodeStored(_ data: Data) throws -> UserSettings {
        do {
            let envelope = try JSONDecoder().decode(StoredSettings.self, from: data)
            guard envelope.version == Self.storageVersion, Self.isValid(envelope.settings) else {
                throw UserDefaultsSettingsStoreError.corruptStoredSettings
            }
            return envelope.settings
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
        let decoded: [LegacyProviderSettings] = decodeLegacyArray(domain["llmProviderProfilesV1"])
        var seen = Set<UUID>()
        var result: [ProviderProfile] = []

        for legacyProfile in decoded where seen.insert(legacyProfile.id).inserted {
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
              let host = components.host?.lowercased(),
              !host.isEmpty,
              let url = components.url
        else { return nil }
        if scheme == "https" { return (url, .remoteHTTPS) }
        if scheme == "http", Self.isLoopback(host) { return (url, .loopbackHTTP) }
        return nil
    }

    private func migrateOutputModes(_ domain: [String: Any]) -> (modes: [OutputMode], legacyRawIDs: Set<UUID>) {
        let decoded: [LegacyOutputModeSettings] = decodeLegacyArray(domain["outputModeProfilesV1"])
        var modes: [OutputMode] = [.raw]
        var seen: Set<UUID> = [OutputMode.rawID]
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
        return array.compactMap { element in
            guard JSONSerialization.isValidJSONObject(element),
                  let elementData = try? JSONSerialization.data(withJSONObject: element),
                  let decoded = try? JSONDecoder().decode(T.self, from: elementData)
            else { return nil }
            return decoded
        }
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
              Set(settings.providerProfiles.map(\.id)).count == settings.providerProfiles.count
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
