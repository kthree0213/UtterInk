import Foundation
import UtterInkCore
import UtterInkServices
@testable import UtterInk

actor AppSettingsFake: SettingsStore {
    enum Failure: Error { case requested }

    private var value: UserSettings
    private var calls: [String] = []
    private var saveFailureEnabled = false

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
        if saveFailureEnabled { throw Failure.requested }
        mutation(&value)
        return value
    }

    func recordedCalls() -> [String] { calls }
    func setSaveFailureEnabled(_ enabled: Bool) { saveFailureEnabled = enabled }
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
}

@MainActor
final class AppSystemSettingsFake: SystemSettingsNavigating {
    private(set) var calls: [String] = []

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

    func arm() async -> AsyncStream<Void> {
        calls.append("hotkey.arm")
        await armGate?.wait()
        return AsyncStream { continuation in continuation.finish() }
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
    private var delivered: [(SessionID, String)] = []

    func deliver(_ text: String, sessionID: SessionID) async {
        calls.append("onboarding.deliver")
        delivered.append((sessionID, text))
    }

    func values() async -> AsyncStream<(SessionID, String)> {
        let snapshot = delivered
        calls.append("onboarding.values")
        return AsyncStream { continuation in
            snapshot.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func recordedCalls() -> [String] { calls }
}

struct AppClockFake: AppClock {
    var now: Date = Date(timeIntervalSince1970: 1_721_000_000)

    func sleep(for duration: Duration) async throws {}
}

extension DictationResult {
    static func fixture(finalText: String = "result") -> DictationResult {
        DictationResult(
            sessionID: SessionID(),
            startedAt: Date(timeIntervalSince1970: 1_721_000_000),
            rawText: "raw",
            finalText: finalText,
            source: .raw,
            warning: nil,
            delivery: nil
        )
    }
}
