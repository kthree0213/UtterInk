import SwiftUI
import UtterInkCore

enum SettingsRoute: String, CaseIterable, Identifiable, Hashable {
    case general
    case permissions
    case recognitionLanguage
    case speechModel
    case shortcuts
    case outputModes
    case provider
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .permissions: return "Permissions"
        case .recognitionLanguage: return "Recognition Language"
        case .speechModel: return "Speech Model"
        case .shortcuts: return "Shortcuts"
        case .outputModes: return "Output Modes"
        case .provider: return "Provider"
        case .diagnostics: return "Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .recognitionLanguage: return "character.cursor.ibeam"
        case .speechModel: return "internaldrive"
        case .shortcuts: return "keyboard"
        case .outputModes: return "text.badge.checkmark"
        case .provider: return "network"
        case .diagnostics: return "stethoscope"
        }
    }

    var isPlaceholder: Bool {
        false
    }
}

actor SettingsMutationCoordinator {
    private let store: any SettingsStore

    init(store: any SettingsStore) {
        self.store = store
    }

    func current() async throws -> UserSettings {
        try await store.current()
    }

    func update(
        _ mutation: @escaping @Sendable (inout UserSettings) -> Void
    ) async throws -> UserSettings {
        try await store.update(mutation)
    }
}

@MainActor
final class SettingsRootModel {
    static let supportedInterfaceLanguages = ["English"]

    let general: GeneralSettingsViewModel
    let permissions: PermissionSettingsViewModel
    let recognitionLanguage: RecognitionLanguageSettingsViewModel
    let speechModel: SpeechModelSettingsViewModel
    let shortcuts: ShortcutSettingsViewModel
    let outputModes: OutputModeSettingsViewModel
    let provider: ProviderSettingsViewModel
    let diagnostics: DiagnosticsSettingsViewModel

    init(
        dependencies: AppFeatureDependencies,
        controller: any DictationControlling,
        setFloatingRecorderEnabled: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let writer = SettingsMutationCoordinator(store: dependencies.settings)
        general = GeneralSettingsViewModel(
            settings: dependencies.settings,
            writer: writer,
            controller: controller,
            launchAtLogin: dependencies.launchAtLogin,
            setFloatingRecorderEnabled: setFloatingRecorderEnabled
        )
        permissions = PermissionSettingsViewModel(
            permissions: dependencies.permissions,
            systemSettings: dependencies.systemSettings
        )
        recognitionLanguage = RecognitionLanguageSettingsViewModel(
            settings: dependencies.settings,
            writer: writer
        )
        speechModel = SpeechModelSettingsViewModel(
            controller: controller,
            settings: dependencies.settings
        )
        shortcuts = ShortcutSettingsViewModel(
            settings: dependencies.settings,
            writer: writer,
            hotkey: dependencies.hotkeyConfiguration
        )
        outputModes = OutputModeSettingsViewModel(
            settings: dependencies.settings,
            writer: writer
        )
        provider = ProviderSettingsViewModel(
            settings: dependencies.settings,
            writer: writer,
            credentials: dependencies.credentials,
            migration: dependencies.credentialMigration,
            validation: dependencies.providerValidation
        )
        diagnostics = DiagnosticsSettingsViewModel(
            exporter: dependencies.diagnosticsExport,
            snapshotProvider: {
                try await DiagnosticsSettingsViewModel.liveSnapshot(
                    settings: dependencies.settings,
                    controller: controller,
                    permissions: dependencies.permissions
                )
            }
        )
    }
}

struct SettingsRootView: View {
    @State private var selectedRoute: SettingsRoute? = .general
    private let model: SettingsRootModel

    init(model: SettingsRootModel) {
        self.model = model
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsRoute.allCases, selection: $selectedRoute) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
                    .accessibilityValue(route == selectedRoute ? "Current" : "")
                    .accessibilityIdentifier("settings.route.\(route.rawValue)")
            }
            .navigationTitle("Settings")
            .accessibilityLabel("Settings sections")
            .accessibilityIdentifier("settings.sidebar")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            destination(selectedRoute ?? .general)
        }
        .frame(minWidth: 720, minHeight: 500)
        .accessibilityIdentifier("settings.root")
    }

    @ViewBuilder
    private func destination(_ route: SettingsRoute) -> some View {
        switch route {
        case .general:
            GeneralSettingsView(model: model.general)
        case .permissions:
            PermissionSettingsView(model: model.permissions)
        case .recognitionLanguage:
            RecognitionLanguageSettingsView(model: model.recognitionLanguage)
        case .speechModel:
            SpeechModelSettingsView(model: model.speechModel)
        case .shortcuts:
            ShortcutSettingsView(model: model.shortcuts)
        case .outputModes:
            OutputModeSettingsView(model: model.outputModes)
        case .provider:
            ProviderSettingsView(model: model.provider)
        case .diagnostics:
            DiagnosticsSettingsView(model: model.diagnostics)
        }
    }
}
