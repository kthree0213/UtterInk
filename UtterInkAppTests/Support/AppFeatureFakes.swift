import Foundation
import XCTest
import UtterInkCore
import UtterInkServices
@testable import UtterInk

actor AppSettingsFake: SettingsStore {
    enum Failure: Error { case requested }

    private var value: UserSettings
    private var calls: [String] = []
    private var saveFailureEnabled = false
    private var updateGate: AppBootstrapGate?

    init(value: UserSettings = .p0Default) {
        self.value = value
    }

    func current() async throws -> UserSettings {
        calls.append("settings.current")
        return value
    }

    func save(_ settings: UserSettings) async throws {
        calls.append("settings.save")
        if saveFailureEnabled { throw Failure.requested }
        value = settings
    }

    func update(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async throws -> UserSettings {
        calls.append("settings.update")
        await updateGate?.wait()
        if saveFailureEnabled { throw Failure.requested }
        mutation(&value)
        return value
    }

    func recordedCalls() -> [String] { calls }
    func setSaveFailureEnabled(_ enabled: Bool) { saveFailureEnabled = enabled }
    func setUpdateGate(_ gate: AppBootstrapGate?) { updateGate = gate }
}

actor AppPermissionFake: PermissionService {
    var microphone: PermissionState = .granted
    var accessibility: PermissionState = .granted
    private var calls: [String] = []

    func microphoneState() async -> PermissionState {
        calls.append("permissions.microphone")
        return microphone
    }

    func accessibilityState() async -> PermissionState {
        calls.append("permissions.accessibility")
        return accessibility
    }

    func recordedCalls() -> [String] { calls }
    func setMicrophone(_ state: PermissionState) { microphone = state }
    func setAccessibility(_ state: PermissionState) { accessibility = state }
}

@MainActor
final class AppSystemSettingsFake: SystemSettingsNavigating {
    private(set) var calls: [String] = []

    var openCount: Int { calls.count }

    func open(_ destination: SystemSettingsDestination) {
        calls.append("systemSettings.open.\(destination)")
    }
}

@MainActor
final class AppLaunchAtLoginFake: LaunchAtLoginManaging {
    var state: LaunchAtLoginState = .disabled
    var nextStateAfterEnable: LaunchAtLoginState = .enabled
    private(set) var calls: [String] = []

    func refresh() {
        calls.append("launchAtLogin.refresh")
    }

    func setEnabled(_ enabled: Bool) async {
        calls.append("launchAtLogin.set.\(enabled)")
        state = enabled ? nextStateAfterEnable : .disabled
    }
}

@MainActor
final class AppHotkeyFake: HotkeyProbing, HotkeyConfiguring {
    var currentMode: ShortcutMode = .toggle
    var hasConflict = false
    var hasConfiguredShortcut = true
    var armGate: AppBootstrapGate?
    private(set) var calls: [String] = []
    private var probeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func arm() async -> AsyncStream<Void> {
        calls.append("hotkey.arm")
        return await makeProbeStream()
    }

    func armProbeOnly() async -> AsyncStream<Void> {
        calls.append("hotkey.armProbeOnly")
        return await makeProbeStream()
    }

    private func makeProbeStream() async -> AsyncStream<Void> {
        await armGate?.wait()
        let id = UUID()
        return AsyncStream { continuation in
            probeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.probeContinuations[id] = nil }
            }
        }
    }

    func emitConfiguredShortcut() {
        probeContinuations.values.forEach { $0.yield(()) }
    }

    func finishProbe() {
        probeContinuations.values.forEach { $0.finish() }
        probeContinuations.removeAll()
    }

    func reset() {
        calls.append("hotkey.reset")
        hasConfiguredShortcut = false
        hasConflict = false
    }

    func reconfigure(mode: ShortcutMode) {
        calls.append("hotkey.reconfigure.\(mode.rawValue)")
        currentMode = mode
    }
}

actor AppCredentialFake: CredentialStore {
    private var calls: [String] = []

    func read(profileID: UUID) async throws -> SessionSecret? {
        calls.append("credential.read.\(profileID.uuidString)")
        return nil
    }

    func write(_ secret: SessionSecret, profileID: UUID) async throws {
        calls.append("credential.write.\(profileID.uuidString)")
    }

    func delete(profileID: UUID) async throws {
        calls.append("credential.delete.\(profileID.uuidString)")
    }

    func recordedCalls() -> [String] { calls }
}

actor AppCredentialMigrationFake: CredentialMigrationService {
    var result: CredentialMigrationResult = .noLegacyValue
    private var calls: [String] = []

    func migrate(profileID: UUID) async -> CredentialMigrationResult {
        calls.append("migration.migrate.\(profileID.uuidString)")
        return result
    }

    func resolve(
        profileID: UUID,
        choice: CredentialConflictChoice
    ) async -> CredentialMigrationResult {
        calls.append("migration.resolve.\(profileID.uuidString).\(choice)")
        return result
    }

    func recordedCalls() -> [String] { calls }
}

actor AppProviderValidationFake: ProviderValidationService {
    var result: ProviderValidationResult = .failed(.credentialMissing)
    private var calls: [String] = []

    func validate(
        profile: ProviderProfile,
        credential: SessionSecret
    ) async -> ProviderValidationResult {
        calls.append("provider.validate.\(profile.id.uuidString)")
        return result
    }

    func recordedCalls() -> [String] { calls }
}

@MainActor
final class AppDiagnosticsExportFake: DiagnosticsExporting {
    private(set) var calls: [String] = []
    var data = Data("{}".utf8)

    func export(_ snapshot: DiagnosticsSnapshot) -> Data {
        calls.append("diagnostics.export")
        return data
    }
}

actor AppOnboardingSinkFake: OnboardingTestSink {
    private var calls: [String] = []
    private var continuations: [UUID: AsyncStream<(SessionID, String)>.Continuation] = [:]

    func deliver(_ text: String, sessionID: SessionID) async {
        calls.append("onboarding.deliver")
        continuations.values.forEach { $0.yield((sessionID, text)) }
    }

    func values() async -> AsyncStream<(SessionID, String)> {
        calls.append("onboarding.values")
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func recordedCalls() -> [String] { calls }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

struct AppClockFake: AppClock {
    var now: Date = Date(timeIntervalSince1970: 1_721_000_000)

    func sleep(for duration: Duration) async throws {}
}

extension DictationResult {
    static func fixture(
        finalText: String = "result",
        source: ResultSource = .raw
    ) -> DictationResult {
        DictationResult(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_721_000_000),
            rawText: "raw",
            finalText: finalText,
            source: source,
            warning: nil,
            delivery: nil
        )
    }
}

@MainActor
struct OnboardingHarness {
    let settings: AppSettingsFake
    let permissions: AppPermissionFake
    let systemSettings: AppSystemSettingsFake
    let hotkeyProbe: AppHotkeyFake
    let onboardingSink: AppOnboardingSinkFake
    let controller: RecordingIntentControllerSpy
    let model: OnboardingViewModel

    init(settingsValue: UserSettings = .p0Default) {
        settings = AppSettingsFake(value: settingsValue)
        permissions = AppPermissionFake()
        systemSettings = AppSystemSettingsFake()
        hotkeyProbe = AppHotkeyFake()
        onboardingSink = AppOnboardingSinkFake()
        controller = RecordingIntentControllerSpy()
        controller.historyControlStatus = .settled(enabled: settingsValue.historyEnabled)
        controller.historyChangeHandler = { [settings] enabled in
            do {
                _ = try await settings.update { $0.historyEnabled = enabled }
                return true
            } catch {
                return false
            }
        }
        controller.speechModelCatalog = [
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
        ]
        model = OnboardingViewModel(
            settings: settings,
            controller: controller,
            permissions: permissions,
            hotkeyProbe: hotkeyProbe,
            onboardingSink: onboardingSink,
            systemSettings: systemSettings
        )
    }

    func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}
