import Foundation

public protocol SettingsStore: Sendable {
    func current() async throws -> UserSettings
    func save(_ settings: UserSettings) async throws
}

public protocol HistoryStore: Sendable {
    func generation() async -> UInt64
    func appendRaw(_ record: HistoryRecord, expectedGeneration: UInt64) async throws
    func updateResult(sessionID: SessionID, finalText: String, source: ResultSource, warning: DiagnosticCode?, delivery: DeliveryOutcome?, outcome: HistoryOutcome, expectedGeneration: UInt64) async throws
    func delete(sessionID: SessionID) async throws
    func setEnabled(_ enabled: Bool) async throws -> UInt64
    func clear() async throws -> UInt64
    func load() async throws -> [HistoryRecord]
}

public protocol CredentialStore: Sendable {
    func read(profileID: UUID) async throws -> SessionSecret?
    func write(_ secret: SessionSecret, profileID: UUID) async throws
    func delete(profileID: UUID) async throws
}

public enum CredentialMigrationResult: Equatable, Sendable {
    case noLegacyValue
    case migrated
    case alreadySecure
    case cleanupPending
    case conflict
    case inaccessible
}

public enum CredentialConflictChoice: Equatable, Sendable {
    case keepSecure
    case replaceSecureWithLegacy
}

public protocol CredentialMigrationService: Sendable {
    func migrate(profileID: UUID) async -> CredentialMigrationResult
    func resolve(profileID: UUID, choice: CredentialConflictChoice) async -> CredentialMigrationResult
}

public protocol AudioRecordingService: Sendable {
    func requestPermission() async -> PermissionState
    func start(levels: @escaping @Sendable (Float) -> Void) async throws -> RecordingHandle
    func stop(_ handle: RecordingHandle) async throws -> URL
    func cancel(_ handle: RecordingHandle) async
}

public protocol SpeechModelService: Sendable {
    func state() async -> SpeechModelState
    func prepare(modelID: String, token: EffectToken) async -> AsyncStream<SpeechModelState>
    func cancelPreparation() async
    func acquireReadyModel(modelID: String, token: EffectToken) async throws -> SpeechModelLease
    func release(_ lease: SpeechModelLease) async
    func deleteCachedModel(modelID: String) async throws
}

public protocol TranscriptionService: Sendable {
    func transcribe(
        audioURL: URL,
        model: SpeechModelLease,
        configuration: RecognitionConfiguration,
        token: EffectToken
    ) async throws -> String
}

public protocol PolishingService: Sendable {
    func polish(rawText: String, snapshot: SessionSnapshot, token: EffectToken) async throws -> String
}

public enum ProviderValidationResult: Equatable, Sendable {
    case ready(normalizedHost: String, modelID: String)
    case failed(DiagnosticCode)
}

public protocol ProviderValidationService: Sendable {
    func validate(
        profile: ProviderProfile,
        credential: SessionSecret
    ) async -> ProviderValidationResult
}

public protocol DeliveryService: Sendable {
    func deliver(
        text: String,
        to target: DeliveryTarget,
        preference: DeliveryPreference,
        token: EffectToken
    ) async -> DeliveryOutcome
    func copyExplicitly(text: String, token: EffectToken) async -> DeliveryOutcome
}

public protocol OnboardingTestSink: Sendable {
    func deliver(_ text: String, sessionID: SessionID) async
    func values() async -> AsyncStream<(SessionID, String)>
}

public protocol TargetSnapshotService: Sendable {
    func snapshotTarget() async -> DeliveryTarget
}

public protocol PermissionService: Sendable {
    func microphoneState() async -> PermissionState
    func accessibilityState() async -> PermissionState
}

public protocol DiagnosticsSink: Sendable {
    func record(stage: PipelineStage, code: DiagnosticCode?) async
}

public enum StartContext: Equatable, Sendable {
    case focusedExternal
    case onboardingTest
}

public enum UserIntent: Equatable, Sendable {
    case start(StartContext)
    case stop
    case cancel
    case acknowledge
    case copyResult(SessionID)
    case pasteAgain(SessionID)
    case retryPolishing(SessionID)
    case deleteResult(SessionID)
    case setHistoryEnabled(Bool)
    case clearHistory
}

@MainActor
public protocol DictationControlling: AnyObject {
    var state: PipelineState { get }
    var speechModelState: SpeechModelState { get }
    var volatileResults: [DictationResult] { get }
    var historyRecords: [HistoryRecord] { get }
    var recordingTelemetry: RecordingTelemetry? { get }
    var sessionPresentation: SessionPresentationContext? { get }
    var speechModelCatalog: [SpeechModelDescriptor] { get }

    func bootstrap() async
    func send(_ intent: UserIntent)
    func prepareSpeechModel(_ modelID: String)
    func cancelSpeechModelPreparation()
    func deleteCachedSpeechModel(_ modelID: String)
}
