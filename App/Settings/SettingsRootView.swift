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
        switch self {
        case .general, .permissions, .recognitionLanguage, .shortcuts:
            return false
        case .speechModel, .outputModes, .provider, .diagnostics:
            return true
        }
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
    let shortcuts: ShortcutSettingsViewModel

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
        shortcuts = ShortcutSettingsViewModel(
            settings: dependencies.settings,
            writer: writer,
            hotkey: dependencies.hotkeyConfiguration
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
            }
            .navigationTitle("Settings")
        } detail: {
            destination(selectedRoute ?? .general)
        }
        .frame(minWidth: 720, minHeight: 500)
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
        case .shortcuts:
            ShortcutSettingsView(model: model.shortcuts)
        case .speechModel, .outputModes, .provider, .diagnostics:
            ContentUnavailableView(
                "\(route.title) is not installed yet",
                systemImage: route.systemImage,
                description: Text("This section will become available in a later product task.")
            )
            .navigationTitle(route.title)
        }
    }
}
