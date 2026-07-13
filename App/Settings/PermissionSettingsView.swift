import Observation
import SwiftUI
import UtterInkCore

struct PermissionRowPresentation: Equatable {
    let title: String
    let statusText: String
    let symbol: String

    init(title: String, state: PermissionState) {
        self.title = title
        switch (title, state) {
        case ("Microphone", .granted):
            statusText = "Allowed"
            symbol = "mic.fill"
        case ("Microphone", .denied):
            statusText = "Denied"
            symbol = "mic.slash.fill"
        case ("Microphone", .notDetermined):
            statusText = "Not Requested"
            symbol = "mic.badge.plus"
        case (_, .granted):
            statusText = "Allowed"
            symbol = "checkmark.shield.fill"
        case (_, .denied):
            statusText = "Denied"
            symbol = "exclamationmark.shield.fill"
        case (_, .notDetermined):
            statusText = "Not Requested"
            symbol = "questionmark.shield"
        }
    }
}

@MainActor
@Observable
final class PermissionSettingsViewModel {
    private(set) var microphone = PermissionRowPresentation(
        title: "Microphone",
        state: .notDetermined
    )
    private(set) var accessibility = PermissionRowPresentation(
        title: "Accessibility",
        state: .notDetermined
    )

    @ObservationIgnored private let permissions: any PermissionService
    @ObservationIgnored private let systemSettings: any SystemSettingsNavigating

    init(
        permissions: any PermissionService,
        systemSettings: any SystemSettingsNavigating
    ) {
        self.permissions = permissions
        self.systemSettings = systemSettings
    }

    func refresh() async {
        async let microphoneState = permissions.microphoneState()
        async let accessibilityState = permissions.accessibilityState()
        microphone = await PermissionRowPresentation(
            title: "Microphone",
            state: microphoneState
        )
        accessibility = await PermissionRowPresentation(
            title: "Accessibility",
            state: accessibilityState
        )
    }

    func openMicrophoneSettings() {
        systemSettings.open(.microphone)
    }

    func openAccessibilitySettings() {
        systemSettings.open(.accessibility)
    }
}

struct PermissionSettingsView: View {
    @Bindable var model: PermissionSettingsViewModel

    var body: some View {
        Form {
            permissionSection(
                presentation: model.microphone,
                explanation: "Microphone access lets UtterInk record speech for local transcription.",
                action: model.openMicrophoneSettings
            )
            permissionSection(
                presentation: model.accessibility,
                explanation: "Accessibility lets UtterInk send a guarded paste event to the original target. Dictation and explicit Copy still work without it.",
                action: model.openAccessibilitySettings
            )
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.permissions")
        .utterInkAccessibilityAnnouncement(
            "Permissions updated. Microphone \(model.microphone.statusText). Accessibility \(model.accessibility.statusText)."
        )
        .navigationTitle("Permissions")
        .task { await model.refresh() }
    }

    private func permissionSection(
        presentation: PermissionRowPresentation,
        explanation: String,
        action: @escaping () -> Void
    ) -> some View {
        Section(presentation.title) {
            Label(presentation.statusText, systemImage: presentation.symbol)
                .accessibilityLabel("\(presentation.title) permission")
                .accessibilityValue(presentation.statusText)
                .accessibilityIdentifier("settings.permissions.\(identifierName(for: presentation)).status")
                .accessibilityAddTraits(.updatesFrequently)
            Text(explanation).foregroundStyle(.secondary)
            Button("Open \(presentation.title) Settings", action: action)
                .accessibilityIdentifier("settings.permissions.\(identifierName(for: presentation)).open")
        }
    }

    private func identifierName(for presentation: PermissionRowPresentation) -> String {
        presentation.title.lowercased()
    }
}
