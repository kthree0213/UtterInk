#if DEBUG
import Foundation
import Observation
import UtterInkCore
import UtterInkServices

enum UITestScenario: String, CaseIterable {
    case idle
    case requestingPermission
    case recording
    case stopping
    case transcribing
    case polishing
    case delivering
    case polishFallback
    case targetChanged
    case failed
    case history
    case historyActive
    case onboarding

    private static let selector = "-uiTesting"

    static func requested(in arguments: [String]) -> UITestScenario? {
        let selectorIndexes = arguments.indices.filter { arguments[$0] == selector }
        guard !selectorIndexes.isEmpty else { return nil }
        guard selectorIndexes.count == 1 else {
            fatalError("Pass -uiTesting exactly once.")
        }

        let valueIndex = arguments.index(after: selectorIndexes[0])
        guard arguments.indices.contains(valueIndex) else {
            fatalError("-uiTesting requires a scenario name.")
        }
        let value = arguments[valueIndex]
        guard let scenario = UITestScenario(rawValue: value) else {
            let known = allCases.map(\.rawValue).joined(separator: ", ")
            fatalError("Unknown -uiTesting scenario '\(value)'. Expected one of: \(known).")
        }
        return scenario
    }
}

@MainActor
enum UITestCompositionFactory {
    static func make(scenario: UITestScenario) -> AppComposition {
        let clock = UITestClock()
        let settings = UITestSettingsStore(value: scenario.settings)
        let permissions = UITestPermissionService()
        let onboardingSink = InMemoryOnboardingTestSink()
        let controller = UITestDictationController(
            scenario: scenario,
            onboardingSink: onboardingSink
        )
        let model = AppModel(
            controller: controller,
            initialReadiness: .ready,
            bootstrapEnabled: false
        )
        let hotkey = UITestHotkeyService()
        let features = AppFeatureDependencies(
            settings: settings,
            permissions: permissions,
            systemSettings: UITestSystemSettingsNavigator(),
            launchAtLogin: UITestLaunchAtLoginService(),
            hotkeyProbe: hotkey,
            hotkeyConfiguration: hotkey,
            credentials: UITestCredentialStore(),
            credentialMigration: UITestCredentialMigrationService(),
            providerValidation: UITestProviderValidationService(),
            diagnosticsExport: UITestDiagnosticsExporter(),
            onboardingSink: onboardingSink,
            clock: clock
        )
        return AppComposition(
            model: model,
            features: features,
            floatingWindowController: FloatingWindowController(model: model, clock: clock),
            automaticallyShowsOnboarding: scenario == .onboarding
        )
    }
}

private extension UITestScenario {
    var settings: UserSettings {
        var settings = UserSettings.p0Default
        settings.showFloatingRecorder = true
        settings.onboardingCompletedV2 = self != .onboarding
        settings.onboardingStep = 0
        return settings
    }
}

private actor UITestSettingsStore: SettingsStore {
    private var value: UserSettings

    init(value: UserSettings) {
        self.value = value
    }

    func current() -> UserSettings { value }

    func save(_ settings: UserSettings) {
        value = settings
    }

    func update(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) -> UserSettings {
        mutation(&value)
        return value
    }
}

private actor UITestPermissionService: PermissionService {
    func microphoneState() -> PermissionState { .granted }
    func accessibilityState() -> PermissionState { .granted }
}

@MainActor
private final class UITestSystemSettingsNavigator: SystemSettingsNavigating {
    func open(_ destination: SystemSettingsDestination) {}
}

@MainActor
private final class UITestLaunchAtLoginService: LaunchAtLoginManaging {
    private(set) var state: LaunchAtLoginState = .disabled

    func refresh() {}

    func setEnabled(_ enabled: Bool) async {
        state = enabled ? .enabled : .disabled
    }
}

@MainActor
private final class UITestHotkeyService: HotkeyProbing, HotkeyConfiguring {
    private(set) var currentMode: ShortcutMode = .toggle
    private(set) var hasConflict = false
    private(set) var hasConfiguredShortcut = true
    private(set) var usesDefaultRightOption = true
    private(set) var shortcutDescription = "Right Option"

    func arm() async -> AsyncStream<Void> { finishedStream() }
    func armProbeOnly() async -> AsyncStream<Void> { finishedStream() }

    func reconfigure(mode: ShortcutMode) {
        currentMode = mode
    }

    func reset() {
        hasConfiguredShortcut = true
        hasConflict = false
        usesDefaultRightOption = true
        shortcutDescription = "Right Option"
    }

    private func finishedStream() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor UITestCredentialStore: CredentialStore {
    private var values: [UUID: SessionSecret] = [:]

    func read(profileID: UUID) -> SessionSecret? { values[profileID] }

    func write(_ secret: SessionSecret, profileID: UUID) {
        values[profileID] = secret
    }

    func delete(profileID: UUID) {
        values[profileID] = nil
    }
}

private actor UITestCredentialMigrationService: CredentialMigrationService {
    func migrate(profileID: UUID) -> CredentialMigrationResult { .noLegacyValue }

    func resolve(
        profileID: UUID,
        choice: CredentialConflictChoice
    ) -> CredentialMigrationResult {
        .noLegacyValue
    }
}

private actor UITestProviderValidationService: ProviderValidationService {
    func validate(
        profile: ProviderProfile,
        credential: SessionSecret
    ) -> ProviderValidationResult {
        .ready(
            normalizedHost: normalizedHost(for: profile),
            modelID: profile.modelID
        )
    }

    func discoverModels(
        profile: ProviderProfile,
        credential: SessionSecret
    ) -> ProviderModelDiscoveryResult {
        .ready(
            normalizedHost: normalizedHost(for: profile),
            modelIDs: [profile.modelID, "fixture-model"]
        )
    }

    private func normalizedHost(for profile: ProviderProfile) -> String {
        if let endpoint = try? EndpointValidator.validate(profile.baseURL.absoluteString) {
            return endpoint.displayAuthority
        }
        return profile.baseURL.host ?? "fixture.invalid"
    }
}

@MainActor
private final class UITestDiagnosticsExporter: DiagnosticsExporting {
    func export(_ snapshot: DiagnosticsSnapshot) -> Data {
        Data("{\"schemaVersion\":1}".utf8)
    }
}

private struct UITestClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_721_000_000)

    func sleep(for duration: Duration) async throws {}
}

@MainActor
@Observable
private final class UITestDictationController: DictationControlling {
    private static let firstSession = SessionID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    private static let secondSession = SessionID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    )
    private static let thirdSession = SessionID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
    )
    private static let fixtureDate = Date(timeIntervalSince1970: 1_721_000_000)

    var state: PipelineState
    var speechModelState: SpeechModelState = .ready(modelID: "small")
    var speechModelCacheActionStatus: SpeechModelCacheActionStatus = .idle
    var volatileResults: [DictationResult]
    var historyRecords: [HistoryRecord]
    var historyControlStatus: HistoryControlStatus = .settled(enabled: true)
    var recordingTelemetry: RecordingTelemetry?
    var sessionPresentation: SessionPresentationContext? = SessionPresentationContext(
        deliveryPreference: .automaticPaste
    )
    let speechModelCatalog: [SpeechModelDescriptor] = [
        SpeechModelDescriptor(
            id: "base",
            displayName: "Base",
            approximateBytes: 150_000_000,
            preset: "Fast"
        ),
        SpeechModelDescriptor(
            id: "small",
            displayName: "Small",
            approximateBytes: 500_000_000,
            preset: "Recommended"
        ),
        SpeechModelDescriptor(
            id: "large-v3",
            displayName: "Large V3",
            approximateBytes: 1_600_000_000,
            preset: "Best Quality"
        ),
    ]
    var cachedSpeechModelIDs: Set<String> = ["small"]
    var activeSpeechModelID: String? = "small"
    var preparingSpeechModelID: String?

    private let onboardingSink: any OnboardingTestSink
    private var lastStartContext: StartContext?

    init(scenario: UITestScenario, onboardingSink: any OnboardingTestSink) {
        self.onboardingSink = onboardingSink
        let fixture = Self.fixture(for: scenario)
        state = fixture.state
        volatileResults = fixture.volatileResults
        historyRecords = fixture.historyRecords
        recordingTelemetry = fixture.recordingTelemetry
    }

    func bootstrap() async {}

    func send(_ intent: UserIntent) {
        switch intent {
        case let .start(context):
            lastStartContext = context
            sessionPresentation = SessionPresentationContext(
                deliveryPreference: .automaticPaste,
                destination: context == .onboardingTest
                    ? .onboardingTest
                    : .external
            )
            let sessionID = Self.thirdSession
            state = Self.pipelineState(stage: .recording, sessionID: sessionID)
            recordingTelemetry = RecordingTelemetry(
                startedAt: Self.fixtureDate,
                inputLevel: 0.62
            )

        case .stop:
            let sessionID = state.sessionID ?? Self.thirdSession
            let result = Self.result(
                sessionID: sessionID,
                rawText: "utterink-ui-onboarding-raw-canary",
                finalText: "utterink-ui-onboarding-raw-canary",
                source: .raw,
                warning: nil,
                delivery: lastStartContext == .onboardingTest
                    ? .deliveredToOnboardingTest
                    : .pasteEventDispatched
            )
            state = Self.pipelineState(stage: .completed, result: result)
            volatileResults = [result] + volatileResults.filter { $0.sessionID != sessionID }
            recordingTelemetry = nil
            if lastStartContext == .onboardingTest {
                let onboardingSink = onboardingSink
                Task {
                    await onboardingSink.deliver(result.finalText, sessionID: sessionID)
                }
            }

        case .cancel:
            state = .idle
            recordingTelemetry = nil
            sessionPresentation = nil
            lastStartContext = nil

        case .acknowledge:
            state = .idle

        case let .copyResult(sessionID):
            replaceDelivery(for: sessionID, with: .copiedByUser)

        case let .pasteAgain(sessionID):
            replaceDelivery(for: sessionID, with: .pasteEventDispatched)

        case let .retryPolishing(sessionID):
            replaceResult(sessionID: sessionID) { result in
                Self.result(
                    sessionID: result.sessionID,
                    startedAt: result.startedAt,
                    rawText: result.rawText,
                    finalText: "Deterministic polished retry",
                    source: .polished,
                    warning: nil,
                    delivery: result.delivery,
                    persistence: result.persistence
                )
            }

        case let .deleteResult(sessionID):
            volatileResults.removeAll { $0.sessionID == sessionID }
            historyRecords.removeAll { $0.sessionID == sessionID }
            if state.result?.sessionID == sessionID { state = .idle }

        case let .setHistoryEnabled(enabled):
            historyControlStatus = .settled(enabled: enabled)

        case .clearHistory:
            state = .idle
            recordingTelemetry = nil
            sessionPresentation = nil
            historyRecords = []
            volatileResults = []
            lastStartContext = nil
        }
    }

    func prepareSpeechModel(_ modelID: String) {
        cachedSpeechModelIDs.insert(modelID)
        activeSpeechModelID = modelID
        preparingSpeechModelID = nil
        speechModelState = .ready(modelID: modelID)
    }

    func refreshSpeechModelCache() async {}

    func cancelSpeechModelPreparation() {
        preparingSpeechModelID = nil
    }

    func deleteCachedSpeechModel(_ modelID: String) {
        cachedSpeechModelIDs.remove(modelID)
        if activeSpeechModelID == modelID { activeSpeechModelID = nil }
        speechModelState = .missing(modelID: modelID)
        speechModelCacheActionStatus = .deleted(modelID: modelID)
    }

    private func replaceDelivery(
        for sessionID: SessionID,
        with delivery: DeliveryOutcome
    ) {
        replaceResult(sessionID: sessionID) { result in
            Self.result(
                sessionID: result.sessionID,
                startedAt: result.startedAt,
                rawText: result.rawText,
                finalText: result.finalText,
                source: result.source,
                warning: result.warning,
                delivery: delivery,
                persistence: result.persistence
            )
        }
    }

    private func replaceResult(
        sessionID: SessionID,
        mutation: (DictationResult) -> DictationResult
    ) {
        var replacedVolatileResult = false
        volatileResults = volatileResults.map { result in
            guard result.sessionID == sessionID else { return result }
            replacedVolatileResult = true
            return mutation(result)
        }

        if !replacedVolatileResult,
           let record = historyRecords.first(where: { $0.sessionID == sessionID }) {
            let current = Self.result(
                sessionID: record.sessionID,
                startedAt: record.startedAt,
                rawText: record.rawText,
                finalText: record.finalText ?? record.rawText,
                source: record.source,
                warning: record.warning,
                delivery: record.delivery,
                persistence: .persistent
            )
            volatileResults.insert(mutation(current), at: 0)
        }

        if let result = state.result, result.sessionID == sessionID {
            state.result = mutation(result)
        }
    }

    private static func fixture(
        for scenario: UITestScenario
    ) -> (
        state: PipelineState,
        volatileResults: [DictationResult],
        historyRecords: [HistoryRecord],
        recordingTelemetry: RecordingTelemetry?
    ) {
        switch scenario {
        case .idle, .onboarding:
            return (.idle, [], [], nil)

        case .requestingPermission:
            return (
                pipelineState(stage: .requestingPermission, sessionID: firstSession),
                [],
                [],
                nil
            )

        case .recording:
            return (
                pipelineState(stage: .recording, sessionID: firstSession),
                [],
                [],
                RecordingTelemetry(startedAt: fixtureDate, inputLevel: 0.62)
            )

        case .stopping:
            return (
                pipelineState(stage: .stopping, sessionID: firstSession),
                [],
                [],
                nil
            )

        case .transcribing:
            return (
                pipelineState(stage: .transcribing, sessionID: firstSession),
                [],
                [],
                nil
            )

        case .polishing:
            return (
                pipelineState(stage: .polishing, sessionID: firstSession),
                [],
                [],
                nil
            )

        case .delivering:
            let result = result(
                sessionID: firstSession,
                rawText: "utterink-ui-delivering-raw-canary",
                finalText: "utterink-ui-delivering-raw-canary",
                source: .raw,
                warning: nil,
                delivery: nil
            )
            return (pipelineState(stage: .delivering, result: result), [result], [], nil)

        case .polishFallback:
            let result = result(
                sessionID: firstSession,
                rawText: "utterink-ui-polish-fallback-raw-canary",
                finalText: "utterink-ui-polish-fallback-raw-canary",
                source: .rawFallback,
                warning: .polishTransport,
                delivery: .copiedByUser
            )
            return (pipelineState(stage: .completed, result: result), [result], [], nil)

        case .targetChanged:
            let result = result(
                sessionID: firstSession,
                rawText: "utterink-ui-target-changed-raw-canary",
                finalText: "utterink-ui-target-changed-raw-canary",
                source: .raw,
                warning: nil,
                delivery: .manualCopyRequired(.deliveryTargetChanged)
            )
            return (pipelineState(stage: .completed, result: result), [result], [], nil)

        case .failed:
            let result = result(
                sessionID: firstSession,
                rawText: "utterink-ui-failed-raw-canary",
                finalText: "utterink-ui-failed-raw-canary",
                source: .raw,
                warning: nil,
                delivery: .manualCopyRequired(.deliveryDispatch)
            )
            return (
                pipelineState(
                    stage: .failed,
                    result: result,
                    failure: .deliveryDispatch
                ),
                [result],
                [],
                nil
            )

        case .history, .historyActive:
            let records = [
                historyRecord(
                    sessionID: secondSession,
                    startedAt: fixtureDate.addingTimeInterval(-60),
                    rawText: "Original meeting note",
                    finalText: "utterink-ui-history-polished-canary",
                    source: .polished,
                    warning: nil,
                    delivery: .pasteEventDispatched,
                    outcome: .delivered
                ),
                historyRecord(
                    sessionID: firstSession,
                    startedAt: fixtureDate.addingTimeInterval(-120),
                    rawText: "utterink-ui-history-fallback-canary",
                    finalText: "utterink-ui-history-fallback-canary",
                    source: .rawFallback,
                    warning: .polishTransport,
                    delivery: .copiedByUser,
                    outcome: .finalized
                ),
            ]
            if scenario == .historyActive {
                return (
                    pipelineState(stage: .recording, sessionID: thirdSession),
                    [],
                    records,
                    RecordingTelemetry(startedAt: fixtureDate, inputLevel: 0.62)
                )
            }
            return (.idle, [], records, nil)
        }
    }

    private static func pipelineState(
        stage: PipelineStage,
        sessionID: SessionID? = nil,
        result: DictationResult? = nil,
        failure: DiagnosticCode? = nil
    ) -> PipelineState {
        PipelineState(
            stage: stage,
            sessionID: sessionID ?? result?.sessionID,
            token: nil,
            result: result,
            failure: failure.map {
                PipelineFailure(code: $0, recoverableResult: result)
            }
        )
    }

    private static func result(
        sessionID: SessionID,
        startedAt: Date = Date(timeIntervalSince1970: 1_721_000_000),
        rawText: String,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        persistence: ResultPersistence = .volatile
    ) -> DictationResult {
        DictationResult(
            sessionID: sessionID,
            startedAt: startedAt,
            rawText: rawText,
            finalText: finalText,
            source: source,
            warning: warning,
            delivery: delivery,
            persistence: persistence
        )
    }

    private static func historyRecord(
        sessionID: SessionID,
        startedAt: Date,
        rawText: String,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode?,
        delivery: DeliveryOutcome?,
        outcome: HistoryOutcome
    ) -> HistoryRecord {
        HistoryRecord(
            sessionID: sessionID,
            startedAt: startedAt,
            rawText: rawText,
            finalText: finalText,
            source: source,
            warning: warning,
            delivery: delivery,
            outcome: outcome
        )
    }
}
#endif
