import Foundation
import Observation
import SwiftUI
import UtterInkCore
import UtterInkServices

enum ProviderTemplateID: String, CaseIterable, Identifiable, Sendable {
    case openRouter
    case openAI
    case groq
    case together
    case minimax
    case minimaxGlobal
    case deepSeek
    case moonshot
    case siliconFlow
    case alibabaQwen
    case zhipuGLM
    case googleGemini
    case volcanoArk
    case custom

    var id: Self { self }
}

struct ProviderTemplate: Identifiable, Equatable, Sendable {
    let id: ProviderTemplateID
    let title: String
    let fixedBaseURL: String?
    let defaultModelID: String

    static let all: [ProviderTemplate] = [
        ProviderTemplate(id: .openRouter, title: "OpenRouter", fixedBaseURL: "https://openrouter.ai/api/v1", defaultModelID: "openrouter/free"),
        ProviderTemplate(id: .openAI, title: "OpenAI", fixedBaseURL: "https://api.openai.com/v1", defaultModelID: "gpt-4o-mini"),
        ProviderTemplate(id: .groq, title: "Groq", fixedBaseURL: "https://api.groq.com/openai/v1", defaultModelID: "llama-3.3-70b-versatile"),
        ProviderTemplate(id: .together, title: "Together AI", fixedBaseURL: "https://api.together.xyz/v1", defaultModelID: "meta-llama/Llama-3.1-8B-Instruct-Turbo"),
        ProviderTemplate(id: .minimax, title: "MiniMax (China)", fixedBaseURL: "https://api.minimaxi.com/v1", defaultModelID: "MiniMax-M2.7"),
        ProviderTemplate(id: .minimaxGlobal, title: "MiniMax (Global)", fixedBaseURL: "https://api.minimax.io/v1", defaultModelID: "MiniMax-M2.7"),
        ProviderTemplate(id: .deepSeek, title: "DeepSeek", fixedBaseURL: "https://api.deepseek.com/v1", defaultModelID: "deepseek-chat"),
        ProviderTemplate(id: .moonshot, title: "Moonshot", fixedBaseURL: "https://api.moonshot.cn/v1", defaultModelID: "moonshot-v1-8k"),
        ProviderTemplate(id: .siliconFlow, title: "SiliconFlow", fixedBaseURL: "https://api.siliconflow.cn/v1", defaultModelID: "Qwen/Qwen2.5-7B-Instruct"),
        ProviderTemplate(id: .alibabaQwen, title: "Alibaba Qwen (DashScope)", fixedBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModelID: "qwen-turbo"),
        ProviderTemplate(id: .zhipuGLM, title: "Zhipu GLM", fixedBaseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModelID: "glm-4-flash"),
        ProviderTemplate(id: .googleGemini, title: "Google (Gemini)", fixedBaseURL: "https://generativelanguage.googleapis.com/v1beta/openai", defaultModelID: "gemini-2.0-flash"),
        ProviderTemplate(id: .volcanoArk, title: "Volcano Engine (Ark)", fixedBaseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModelID: "doubao-pro-32k"),
        ProviderTemplate(id: .custom, title: "Custom", fixedBaseURL: nil, defaultModelID: "default"),
    ]

    static func template(for id: ProviderTemplateID) -> ProviderTemplate {
        all.first(where: { $0.id == id }) ?? all[all.count - 1]
    }

    static func matching(_ profile: ProviderProfile) -> ProviderTemplate {
        let value = canonicalURLString(profile.baseURL)
        return all.first(where: {
            guard let fixed = $0.fixedBaseURL,
                  let url = URL(string: fixed) else { return false }
            return canonicalURLString(url) == value
        }) ?? template(for: .custom)
    }

    private static func canonicalURLString(_ url: URL) -> String {
        url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum ProviderReadiness: Equatable, Sendable {
    case incomplete
    case notValidated
    case validating
    case ready(normalizedHost: String, modelID: String)
    case failed(DiagnosticCode)
}

private struct ProviderFingerprint: Equatable, Sendable {
    let endpoint: String
    let modelID: String
    let policy: EndpointPolicy
    let credentialRevision: UInt64
}

@MainActor
@Observable
final class ProviderSettingsViewModel {
    static let loopbackOptInLabel =
        "Allow plain HTTP only for a canonical loopback address on this Mac."

    private(set) var profiles: [ProviderProfile] = []
    private(set) var selectedProfileID: UUID?
    private(set) var readiness: [UUID: ProviderReadiness] = [:]
    private(set) var isBusy = false
    private(set) var failureMessage: String?
    private(set) var credentialCleanupPending: Set<UUID> = []

    @ObservationIgnored private let writer: SettingsMutationCoordinator
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let migration: any CredentialMigrationService
    @ObservationIgnored private let validation: any ProviderValidationService
    @ObservationIgnored private var credentialPresence: [UUID: Bool] = [:]
    @ObservationIgnored private var credentialRevision: [UUID: UInt64] = [:]
    @ObservationIgnored private var migrationResults: [UUID: CredentialMigrationResult] = [:]
    @ObservationIgnored private var validatedFingerprints: [UUID: ProviderFingerprint] = [:]

    init(
        settings: any SettingsStore,
        credentials: any CredentialStore,
        migration: any CredentialMigrationService,
        validation: any ProviderValidationService
    ) {
        writer = SettingsMutationCoordinator(store: settings)
        self.credentials = credentials
        self.migration = migration
        self.validation = validation
    }

    init(
        settings: any SettingsStore,
        writer: SettingsMutationCoordinator,
        credentials: any CredentialStore,
        migration: any CredentialMigrationService,
        validation: any ProviderValidationService
    ) {
        self.writer = writer
        self.credentials = credentials
        self.migration = migration
        self.validation = validation
    }

    var egressDisclosure: String? {
        guard let selectedProfileID,
              let profile = profiles.first(where: { $0.id == selectedProfileID }) else {
            return nil
        }
        return egressDisclosure(
            forCandidate: profile.baseURL.absoluteString,
            allowsLoopbackHTTP: profile.policy == .loopbackHTTP
        )
    }

    func egressDisclosure(
        forCandidate value: String,
        allowsLoopbackHTTP: Bool = false
    ) -> String? {
        guard let endpoint = try? EndpointValidator.validate(
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        ), endpoint.policy == .remoteHTTPS || allowsLoopbackHTTP else { return nil }
        return "Audio never leaves this Mac. When polishing is enabled, transcript text is sent to \(endpoint.displayAuthority)."
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        failureMessage = nil
        defer { isBusy = false }

        do {
            let settings = try await writer.current()
            profiles = settings.providerProfiles
            selectedProfileID = settings.selectedProviderProfileID
            readiness = [:]
            validatedFingerprints = [:]

            for profile in profiles {
                migrationResults[profile.id] = await migration.migrate(profileID: profile.id)
                let present = try await credentialIsPresent(profileID: profile.id)
                credentialPresence[profile.id] = present
                credentialRevision[profile.id, default: 0] &+= 1
                readiness[profile.id] = isComplete(profile)
                    ? .notValidated
                    : .incomplete
            }
        } catch {
            failureMessage = "Provider settings could not be loaded. Your current values were kept."
        }
    }

    func canUse(_ mode: OutputMode) -> Bool {
        if mode == .raw { return true }
        guard let selectedProfileID else { return false }
        return statusText(for: selectedProfileID) == "In Use"
    }

    func canSelect(profileID: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              !migrationBlocks(profileID),
              isComplete(profile),
              case .ready = readiness[profileID],
              validatedFingerprints[profileID] == fingerprint(for: profile) else {
            return false
        }
        return true
    }

    func statusText(for profileID: UUID) -> String {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return "Unavailable"
        }
        if migrationBlocks(profileID) { return "Migration Required" }
        guard isComplete(profile) else { return "Incomplete" }

        switch readiness[profileID] ?? .notValidated {
        case .incomplete:
            return "Incomplete"
        case .notValidated:
            return "Not Tested"
        case .validating:
            return "Testing…"
        case .failed:
            return "Validation Failed"
        case .ready:
            guard validatedFingerprints[profileID] == fingerprint(for: profile) else {
                return "Not Tested"
            }
            return selectedProfileID == profileID ? "In Use" : "Ready"
        }
    }

    func normalizedHost(for profileID: UUID) -> String? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        if case let .ready(host, _) = readiness[profileID],
           validatedFingerprints[profileID] == fingerprint(for: profile) {
            return host
        }
        return (try? EndpointValidator.validate(profile.baseURL.absoluteString))?.displayAuthority
    }

    func credentialStatusText(for profileID: UUID) -> String {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return "Unavailable"
        }
        if credentialPresence[profileID] == true { return "Keychain: Stored" }
        return profile.policy == .loopbackHTTP
            ? "Keychain: Optional for loopback"
            : "Keychain: Missing"
    }

    @discardableResult
    func addProfile(
        templateID: ProviderTemplateID,
        title: String,
        baseURL: String,
        modelID: String,
        credential: String,
        allowsLoopbackHTTP: Bool
    ) async -> Bool {
        guard !isBusy else { return false }
        let profile: ProviderProfile
        do {
            profile = try makeProfile(
                id: UUID(),
                templateID: templateID,
                title: title,
                baseURL: baseURL,
                modelID: modelID,
                allowsLoopbackHTTP: allowsLoopbackHTTP
            )
        } catch {
            failureMessage = "Use HTTPS, or explicitly allow a canonical loopback HTTP endpoint. Paths are allowed; credentials, query strings, and fragments are not."
            return false
        }

        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        var credentialInput = credential
        defer { credentialInput.removeAll(keepingCapacity: false) }
        let hasCredential = !credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let secret = hasCredential ? SessionSecret(utf8: credentialInput) : nil
        defer { secret?.clear() }

        do {
            if let secret {
                try await credentials.write(secret, profileID: profile.id)
            }
            let saved = try await writer.update { settings in
                guard !settings.providerProfiles.contains(where: { $0.id == profile.id }) else {
                    return
                }
                settings.providerProfiles.append(profile)
            }
            guard saved.providerProfiles.contains(profile) else {
                throw ProviderDraftError.persistenceConflict
            }
            publish(saved)
            credentialPresence[profile.id] = hasCredential
            credentialRevision[profile.id, default: 0] &+= 1
            migrationResults[profile.id] = .noLegacyValue
            invalidateReadiness(profileID: profile.id)
            return true
        } catch {
            if hasCredential {
                do {
                    try await credentials.delete(profileID: profile.id)
                } catch {
                    credentialCleanupPending.insert(profile.id)
                }
            }
            failureMessage = credentialCleanupPending.contains(profile.id)
                ? "The provider was not saved, and its orphaned Keychain item still needs cleanup."
                : "The provider profile could not be saved. No provider was selected."
            return false
        }
    }

    @discardableResult
    func updateProfile(
        id: UUID,
        templateID: ProviderTemplateID,
        title: String,
        baseURL: String,
        modelID: String,
        credential: String,
        allowsLoopbackHTTP: Bool
    ) async -> Bool {
        guard !isBusy,
              let existing = profiles.first(where: { $0.id == id }) else { return false }
        let sameIDCandidate: ProviderProfile
        do {
            sameIDCandidate = try makeProfile(
                id: id,
                templateID: templateID,
                title: title,
                baseURL: baseURL,
                modelID: modelID,
                allowsLoopbackHTTP: allowsLoopbackHTTP
            )
        } catch {
            failureMessage = "Use HTTPS, or explicitly allow a canonical loopback HTTP endpoint. Paths are allowed; credentials, query strings, and fragments are not."
            return false
        }

        var credentialInput = credential
        defer { credentialInput.removeAll(keepingCapacity: false) }
        let replacesCredential = !credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let endpointChanged = sameIDCandidate.baseURL != existing.baseURL
            || sameIDCandidate.policy != existing.policy

        if endpointChanged || replacesCredential {
            let replacement = ProviderProfile(
                id: UUID(),
                title: sameIDCandidate.title,
                baseURL: sameIDCandidate.baseURL,
                modelID: sameIDCandidate.modelID,
                policy: sameIDCandidate.policy
            )
            return await replaceProfile(
                existing: existing,
                replacement: replacement,
                credential: credentialInput
            )
        }

        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        do {
            let modelChanged = sameIDCandidate.modelID != existing.modelID
            let saved = try await writer.update { settings in
                guard let index = settings.providerProfiles.firstIndex(where: { $0.id == id }) else {
                    return
                }
                settings.providerProfiles[index] = sameIDCandidate
                if modelChanged, settings.selectedProviderProfileID == id {
                    settings.selectedProviderProfileID = nil
                }
            }
            guard saved.providerProfiles.contains(sameIDCandidate) else {
                throw ProviderDraftError.persistenceConflict
            }
            publish(saved)
            if modelChanged { invalidateReadiness(profileID: id) }
            return true
        } catch {
            failureMessage = "The provider profile could not be updated. Its saved values were kept."
            return false
        }
    }

    func deleteProfile(id: UUID) async {
        guard !isBusy, profiles.contains(where: { $0.id == id }) else { return }
        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await writer.update { settings in
                settings.providerProfiles.removeAll { $0.id == id }
                if settings.selectedProviderProfileID == id {
                    settings.selectedProviderProfileID = nil
                }
            }
            guard !saved.providerProfiles.contains(where: { $0.id == id }) else {
                throw ProviderDraftError.persistenceConflict
            }
            publish(saved)
            removePresentationState(profileID: id)
            do {
                try await credentials.delete(profileID: id)
                credentialCleanupPending.remove(id)
            } catch {
                credentialCleanupPending.insert(id)
                failureMessage = "The profile was removed, but its orphaned Keychain item still needs cleanup. No provider uses it."
            }
        } catch {
            failureMessage = "The provider profile could not be deleted. It remains available."
        }
    }

    func retryCredentialCleanup(profileID: UUID) async {
        guard credentialCleanupPending.contains(profileID) else { return }
        do {
            try await credentials.delete(profileID: profileID)
            credentialCleanupPending.remove(profileID)
            failureMessage = nil
        } catch {
            failureMessage = "The orphaned Keychain item could not be removed yet."
        }
    }

    func select(profileID: UUID) async {
        guard !isBusy, canSelect(profileID: profileID) else {
            failureMessage = "Test this complete profile successfully before selecting it."
            return
        }
        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await writer.update { settings in
                guard settings.providerProfiles.contains(where: { $0.id == profileID }) else {
                    return
                }
                settings.selectedProviderProfileID = profileID
            }
            guard saved.selectedProviderProfileID == profileID else {
                throw ProviderDraftError.persistenceConflict
            }
            publish(saved)
        } catch {
            failureMessage = "The provider could not be selected."
        }
    }

    func refreshCredentialPresence(profileID: UUID) async {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        do {
            let present = try await credentialIsPresent(profileID: profileID)
            if credentialPresence[profileID] != present {
                credentialPresence[profileID] = present
                credentialRevision[profileID, default: 0] &+= 1
                invalidateReadiness(profileID: profileID)
            }
            failureMessage = nil
        } catch {
            failureMessage = "The Keychain item could not be checked. No credential value was exposed."
            credentialPresence[profileID] = false
            invalidateReadiness(profileID: profileID)
        }
    }

    func validate(profileID: UUID) async {
        guard !isBusy,
              let profile = profiles.first(where: { $0.id == profileID }),
              !migrationBlocks(profileID),
              isComplete(profile),
              let endpoint = try? EndpointValidator.validate(profile.baseURL.absoluteString),
              endpoint.policy == profile.policy else {
            readiness[profileID] = .incomplete
            return
        }

        isBusy = true
        failureMessage = nil
        let expectedFingerprint = fingerprint(for: profile)
        readiness[profileID] = .validating
        defer { isBusy = false }

        let secret: SessionSecret
        do {
            if let stored = try await credentials.read(profileID: profileID) {
                secret = stored
            } else if profile.policy == .loopbackHTTP {
                secret = SessionSecret(utf8: "")
            } else {
                readiness[profileID] = .incomplete
                credentialPresence[profileID] = false
                return
            }
        } catch {
            readiness[profileID] = .failed(.credentialMissing)
            failureMessage = "The Keychain item could not be read. No credential value was exposed."
            return
        }
        defer { secret.clear() }

        let result = await validation.validate(profile: profile, credential: secret)
        guard let current = profiles.first(where: { $0.id == profileID }),
              fingerprint(for: current) == expectedFingerprint else {
            invalidateReadiness(profileID: profileID)
            return
        }

        switch result {
        case let .ready(normalizedHost, modelID)
            where normalizedHost == endpoint.displayAuthority && modelID == profile.modelID:
            validatedFingerprints[profileID] = expectedFingerprint
            readiness[profileID] = .ready(normalizedHost: normalizedHost, modelID: modelID)
        case .ready:
            validatedFingerprints[profileID] = nil
            readiness[profileID] = .failed(.polishInvalidResponse)
        case let .failed(code):
            validatedFingerprints[profileID] = nil
            readiness[profileID] = .failed(code)
        }
    }

    func migrationMessage(for profileID: UUID) -> String? {
        switch migrationResults[profileID] {
        case .conflict:
            return "A legacy credential conflicts with the secure Keychain item. Choose which secure result to keep."
        case .cleanupPending:
            return "The credential is secure, but legacy plaintext cleanup must finish before polishing can be enabled."
        case .inaccessible:
            return "Legacy credential storage is inaccessible. Restore access or enter a replacement Key before polishing."
        case .migrated:
            return "The credential was moved to Keychain and legacy plaintext was removed."
        case .alreadySecure:
            return "The Keychain credential was kept and legacy plaintext was removed."
        case .noLegacyValue, nil:
            return nil
        }
    }

    func conflictChoices(for profileID: UUID) -> [CredentialConflictChoice] {
        migrationResults[profileID] == .conflict
            ? [.keepSecure, .replaceSecureWithLegacy]
            : []
    }

    func resolveConflict(profileID: UUID, choice: CredentialConflictChoice) async {
        guard !isBusy, migrationResults[profileID] == .conflict else { return }
        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        migrationResults[profileID] = await migration.resolve(
            profileID: profileID,
            choice: choice
        )
        do {
            credentialPresence[profileID] = try await credentialIsPresent(profileID: profileID)
            credentialRevision[profileID, default: 0] &+= 1
        } catch {
            credentialPresence[profileID] = false
        }
        invalidateReadiness(profileID: profileID)
    }

    private func replaceProfile(
        existing: ProviderProfile,
        replacement: ProviderProfile,
        credential: String
    ) async -> Bool {
        isBusy = true
        failureMessage = nil
        defer { isBusy = false }
        let hasCredential = !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let secret = hasCredential ? SessionSecret(utf8: credential) : nil
        defer { secret?.clear() }

        do {
            if let secret {
                try await credentials.write(secret, profileID: replacement.id)
            }
            let saved = try await writer.update { settings in
                guard let index = settings.providerProfiles.firstIndex(where: {
                    $0.id == existing.id
                }) else { return }
                settings.providerProfiles[index] = replacement
                if settings.selectedProviderProfileID == existing.id {
                    settings.selectedProviderProfileID = nil
                }
            }
            guard saved.providerProfiles.contains(replacement),
                  !saved.providerProfiles.contains(where: { $0.id == existing.id }) else {
                throw ProviderDraftError.persistenceConflict
            }
            publish(saved)
            removePresentationState(profileID: existing.id)
            credentialPresence[replacement.id] = hasCredential
            credentialRevision[replacement.id, default: 0] &+= 1
            migrationResults[replacement.id] = .noLegacyValue
            invalidateReadiness(profileID: replacement.id)
            do {
                try await credentials.delete(profileID: existing.id)
            } catch {
                credentialCleanupPending.insert(existing.id)
                failureMessage = "The new profile is saved, but the old orphaned Keychain item still needs cleanup."
            }
            return true
        } catch {
            if hasCredential {
                do {
                    try await credentials.delete(profileID: replacement.id)
                } catch {
                    credentialCleanupPending.insert(replacement.id)
                }
            }
            failureMessage = credentialCleanupPending.contains(replacement.id)
                ? "The provider change was not saved, and its orphaned Keychain item still needs cleanup."
                : "The provider change could not be saved. The previous profile remains unchanged."
            return false
        }
    }

    private func makeProfile(
        id: UUID,
        templateID: ProviderTemplateID,
        title: String,
        baseURL: String,
        modelID: String,
        allowsLoopbackHTTP: Bool
    ) throws -> ProviderProfile {
        let template = ProviderTemplate.template(for: templateID)
        let endpointText = (template.fixedBaseURL ?? baseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = try EndpointValidator.validate(endpointText)
        guard endpoint.policy == .remoteHTTPS
                || (endpoint.policy == .loopbackHTTP && allowsLoopbackHTTP),
              let storageURL = Self.normalizedStorageURL(endpointText) else {
            throw ProviderDraftError.invalidEndpoint
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = cleanTitle.isEmpty ? template.title : cleanTitle
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty && templateID != .custom
            ? template.defaultModelID
            : cleanModel
        guard !effectiveTitle.isEmpty, !effectiveModel.isEmpty else {
            throw ProviderDraftError.incomplete
        }
        return ProviderProfile(
            id: id,
            title: effectiveTitle,
            baseURL: storageURL,
            modelID: effectiveModel,
            policy: endpoint.policy
        )
    }

    private func isComplete(_ profile: ProviderProfile) -> Bool {
        guard !profile.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let endpoint = try? EndpointValidator.validate(profile.baseURL.absoluteString),
              endpoint.policy == profile.policy else { return false }
        switch profile.policy {
        case .remoteHTTPS:
            return credentialPresence[profile.id] == true
        case .loopbackHTTP:
            return true
        }
    }

    private func migrationBlocks(_ profileID: UUID) -> Bool {
        switch migrationResults[profileID] {
        case .conflict, .cleanupPending, .inaccessible:
            return true
        case .noLegacyValue, .migrated, .alreadySecure, nil:
            return false
        }
    }

    private func fingerprint(for profile: ProviderProfile) -> ProviderFingerprint {
        ProviderFingerprint(
            endpoint: profile.baseURL.absoluteString,
            modelID: profile.modelID,
            policy: profile.policy,
            credentialRevision: credentialRevision[profile.id, default: 0]
        )
    }

    private func invalidateReadiness(profileID: UUID) {
        validatedFingerprints[profileID] = nil
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            readiness[profileID] = nil
            return
        }
        readiness[profileID] = isComplete(profile) ? .notValidated : .incomplete
    }

    private func credentialIsPresent(profileID: UUID) async throws -> Bool {
        guard let secret = try await credentials.read(profileID: profileID) else {
            return false
        }
        defer { secret.clear() }
        return (try? secret.withUTF8 {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) ?? false
    }

    private func publish(_ settings: UserSettings) {
        profiles = settings.providerProfiles
        selectedProfileID = settings.selectedProviderProfileID
    }

    private func removePresentationState(profileID: UUID) {
        credentialPresence[profileID] = nil
        credentialRevision[profileID] = nil
        migrationResults[profileID] = nil
        readiness[profileID] = nil
        validatedFingerprints[profileID] = nil
    }

    private nonisolated static func normalizedStorageURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        return components.url
    }
}

private enum ProviderDraftError: Error {
    case invalidEndpoint
    case incomplete
    case persistenceConflict
}

struct ProviderSettingsView: View {
    @Bindable var model: ProviderSettingsViewModel
    @State private var editingID: UUID?
    @State private var templateID: ProviderTemplateID = .openRouter
    @State private var title = "OpenRouter"
    @State private var baseURL = "https://openrouter.ai/api/v1"
    @State private var modelID = "openrouter/free"
    @State private var credential = ""
    @State private var allowsLoopbackHTTP = false

    var body: some View {
        Form {
            Section("Profiles") {
                if model.profiles.isEmpty {
                    Text("No provider is required for Raw output.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.title).font(.headline)
                                Text("\(model.normalizedHost(for: profile.id) ?? "Invalid host") · \(profile.modelID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(model.credentialStatusText(for: profile.id))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(model.statusText(for: profile.id))
                                .foregroundStyle(model.statusText(for: profile.id) == "In Use" ? .green : .secondary)
                        }
                        HStack {
                            Button("Test Connection") {
                                Task { await model.validate(profileID: profile.id) }
                            }
                            Button("Use") {
                                Task { await model.select(profileID: profile.id) }
                            }
                            .disabled(!model.canSelect(profileID: profile.id))
                            Button("Edit") { beginEditing(profile) }
                            Button("Delete", role: .destructive) {
                                Task { await model.deleteProfile(id: profile.id) }
                            }
                        }
                        if let migrationMessage = model.migrationMessage(for: profile.id) {
                            Label(migrationMessage, systemImage: "lock.trianglebadge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        if model.conflictChoices(for: profile.id).contains(.keepSecure) {
                            HStack {
                                Button("Keep Secure Keychain Item") {
                                    Task {
                                        await model.resolveConflict(
                                            profileID: profile.id,
                                            choice: .keepSecure
                                        )
                                    }
                                }
                                Button("Replace Secure Item with Legacy Credential") {
                                    Task {
                                        await model.resolveConflict(
                                            profileID: profile.id,
                                            choice: .replaceSecureWithLegacy
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(editingID == nil ? "Add Provider" : "Edit Provider") {
                Picker("Template", selection: $templateID) {
                    ForEach(ProviderTemplate.all) { template in
                        Text(template.title).tag(template.id)
                    }
                }
                TextField("Name", text: $title)
                if let fixed = ProviderTemplate.template(for: templateID).fixedBaseURL {
                    LabeledContent("Base URL", value: fixed)
                } else {
                    TextField("Base URL", text: $baseURL)
                }
                TextField("Model ID", text: $modelID)
                SecureField("API Key (stored only in Keychain)", text: $credential)
                if templateID == .custom {
                    Toggle(ProviderSettingsViewModel.loopbackOptInLabel, isOn: $allowsLoopbackHTTP)
                }
                if let disclosure = model.egressDisclosure(
                    forCandidate: endpointDraft,
                    allowsLoopbackHTTP: allowsLoopbackHTTP
                ) {
                    Label(disclosure, systemImage: "network")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(editingID == nil ? "Add Profile" : "Save Changes") {
                        saveDraft()
                    }
                    if editingID != nil {
                        Button("Cancel", role: .cancel) { resetDraft() }
                    }
                }
            }
            .disabled(model.isBusy)

            if let disclosure = model.egressDisclosure {
                Section("Data Egress") {
                    Label(disclosure, systemImage: "hand.raised.fill")
                }
            }

            if !model.credentialCleanupPending.isEmpty {
                Section("Keychain Cleanup") {
                    ForEach(
                        model.credentialCleanupPending.sorted { $0.uuidString < $1.uuidString },
                        id: \.self
                    ) { profileID in
                        HStack {
                            Text("Orphaned provider credential")
                            Spacer()
                            Button("Retry Cleanup") {
                                Task {
                                    await model.retryCredentialCleanup(profileID: profileID)
                                }
                            }
                        }
                    }
                }
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Provider")
        .task { await model.load() }
        .onChange(of: templateID) { _, newValue in
            let template = ProviderTemplate.template(for: newValue)
            if editingID == nil { title = template.title }
            if let fixed = template.fixedBaseURL { baseURL = fixed }
            modelID = template.defaultModelID
            if newValue != .custom { allowsLoopbackHTTP = false }
        }
    }

    private var endpointDraft: String {
        ProviderTemplate.template(for: templateID).fixedBaseURL ?? baseURL
    }

    private func beginEditing(_ profile: ProviderProfile) {
        let template = ProviderTemplate.matching(profile)
        editingID = profile.id
        templateID = template.id
        title = profile.title
        baseURL = profile.baseURL.absoluteString
        modelID = profile.modelID
        credential.removeAll(keepingCapacity: false)
        allowsLoopbackHTTP = profile.policy == .loopbackHTTP
    }

    private func saveDraft() {
        let currentEditingID = editingID
        let capturedTemplate = templateID
        let capturedTitle = title
        let capturedBaseURL = baseURL
        let capturedModelID = modelID
        let capturedCredential = credential
        let capturedLoopbackOptIn = allowsLoopbackHTTP
        credential.removeAll(keepingCapacity: false)
        Task {
            let saved = if let currentEditingID {
                await model.updateProfile(
                    id: currentEditingID,
                    templateID: capturedTemplate,
                    title: capturedTitle,
                    baseURL: capturedBaseURL,
                    modelID: capturedModelID,
                    credential: capturedCredential,
                    allowsLoopbackHTTP: capturedLoopbackOptIn
                )
            } else {
                await model.addProfile(
                    templateID: capturedTemplate,
                    title: capturedTitle,
                    baseURL: capturedBaseURL,
                    modelID: capturedModelID,
                    credential: capturedCredential,
                    allowsLoopbackHTTP: capturedLoopbackOptIn
                )
            }
            if saved { resetDraft() }
        }
    }

    private func resetDraft() {
        editingID = nil
        templateID = .openRouter
        title = "OpenRouter"
        baseURL = "https://openrouter.ai/api/v1"
        modelID = "openrouter/free"
        credential.removeAll(keepingCapacity: false)
        allowsLoopbackHTTP = false
    }
}
