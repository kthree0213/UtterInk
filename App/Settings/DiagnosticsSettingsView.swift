import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UtterInkCore
import UtterInkServices

@MainActor
@Observable
final class DiagnosticsSettingsViewModel {
    typealias SnapshotProvider = @MainActor () async throws -> DiagnosticsSnapshot

    private(set) var preview = ""
    private(set) var exportData: Data?
    private(set) var failureMessage: String?
    private(set) var exportStatusMessage: String?
    private(set) var accessibilityEvent: UtterInkAccessibilityEvent?
    private(set) var isPreparing = false

    @ObservationIgnored private let exporter: any DiagnosticsExporting
    @ObservationIgnored private let snapshotProvider: SnapshotProvider?

    init(
        exporter: any DiagnosticsExporting,
        snapshotProvider: SnapshotProvider? = nil
    ) {
        self.exporter = exporter
        self.snapshotProvider = snapshotProvider
    }

    var canExport: Bool { exportData != nil && !preview.isEmpty }

    func refresh(announceCompletion: Bool = false) async {
        guard !isPreparing, let snapshotProvider else { return }
        exportStatusMessage = nil
        isPreparing = true
        defer { isPreparing = false }
        do {
            preparePreview(try await snapshotProvider())
            if canExport, announceCompletion {
                accessibilityEvent = UtterInkAccessibilityEvent(
                    message: "Diagnostics preview refreshed."
                )
            }
        } catch {
            preview = ""
            exportData = nil
            failureMessage = "Current diagnostics could not be read safely. No fallback values were previewed or exported."
        }
    }

    func preparePreview(_ snapshot: DiagnosticsSnapshot) {
        exportStatusMessage = nil
        let data = exporter.export(snapshot)
        guard Self.hasOnlyAllowlistedFields(data),
              let value = String(data: data, encoding: .utf8) else {
            preview = ""
            exportData = nil
            failureMessage = "A safe diagnostics preview could not be prepared. Nothing was exported."
            return
        }
        preview = value
        exportData = data
        failureMessage = nil
    }

    var exportDocument: DiagnosticsJSONDocument? {
        exportData.map(DiagnosticsJSONDocument.init(data:))
    }

    func recordExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            failureMessage = nil
            exportStatusMessage = "Diagnostics exported."
        case .failure:
            exportStatusMessage = nil
            failureMessage = "Diagnostics could not be exported. No file path or system error details were retained."
        }
    }

    static func liveSnapshot(
        settings: any SettingsStore,
        controller: any DictationControlling,
        permissions: any PermissionService
    ) async throws -> DiagnosticsSnapshot {
        let current = try await settings.current()
        let microphone = await permissions.microphoneState()
        let accessibility = await permissions.accessibilityState()
        let selectedProvider = current.selectedProviderProfileID.flatMap { id in
            current.providerProfiles.first(where: { $0.id == id })
        }
        let providerHost = selectedProvider.flatMap {
            (try? EndpointValidator.validate($0.baseURL.absoluteString))?.displayAuthority
        }
        let state = controller.state
        var codes: [DiagnosticCode] = []
        if let failure = state.failure?.code { codes.append(failure) }
        if let warning = state.result?.warning { codes.append(warning) }
        let summary = SafeDiagnosticsSummary(
            lastStage: state.stage,
            diagnosticCodes: codes,
            eventCounts: []
        )
        let version = ProcessInfo.processInfo.operatingSystemVersion

        return DiagnosticsSnapshot(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.0",
            appBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "1",
            operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            architecture: Self.architecture,
            microphonePermission: Self.diagnosticPermission(microphone),
            accessibilityPermission: Self.diagnosticPermission(accessibility),
            speechModelID: current.speechModelID,
            speechModelPhase: Self.modelPhase(controller.speechModelState),
            providerHost: providerHost,
            providerModelID: selectedProvider?.modelID,
            historyEnabled: controller.historyControlStatus.enabled,
            historyItemCount: controller.historyRecords.count,
            summary: summary
        )
    }

    private nonisolated static var architecture: DiagnosticArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    private nonisolated static func diagnosticPermission(
        _ state: PermissionState
    ) -> DiagnosticPermissionState {
        switch state {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .granted: return .granted
        }
    }

    private nonisolated static func modelPhase(
        _ state: SpeechModelState
    ) -> DiagnosticModelPhase {
        switch state {
        case .missing: return .missing
        case .downloading: return .downloading
        case .loading: return .loading
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    private nonisolated static func hasOnlyAllowlistedFields(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        let allowed: Set<String> = [
            "schemaVersion",
            "appVersion",
            "appBuild",
            "operatingSystemVersion",
            "architecture",
            "microphonePermission",
            "accessibilityPermission",
            "speechModelID",
            "speechModelPhase",
            "providerHost",
            "providerModelID",
            "lastStage",
            "historyEnabled",
            "historyItemCount",
            "diagnosticCodes",
            "eventCounts",
        ]
        return Set(dictionary.keys).isSubset(of: allowed)
            && dictionary["schemaVersion"] as? Int == 1
    }
}

struct DiagnosticsJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct DiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsSettingsViewModel
    @State private var showsExporter = false
    @State private var document: DiagnosticsJSONDocument?

    var body: some View {
        Form {
            Section("Safe Preview") {
                if model.preview.isEmpty {
                    Text("Generate a preview to inspect every field before opening the Save Panel.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(model.preview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 280)
                    .accessibilityLabel("Diagnostics preview")
                    .accessibilityValue(model.preview)
                    .accessibilityIdentifier("settings.diagnostics.preview")
                }
                HStack {
                    Button("Refresh Preview") {
                        Task { await model.refresh(announceCompletion: true) }
                    }
                        .accessibilityIdentifier("settings.diagnostics.refresh")
                    Button("Export…") {
                        document = model.exportDocument
                        showsExporter = document != nil
                    }
                    .disabled(!model.canExport)
                    .accessibilityIdentifier("settings.diagnostics.export")
                }
            }

            Section("Privacy") {
                Text("The preview is an allowlisted snapshot. It cannot accept transcripts, prompts, credentials, pasteboard contents, file paths, URL paths, or query strings.")
                    .foregroundStyle(.secondary)
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("settings.diagnostics.error")
                    .accessibilityAddTraits(.updatesFrequently)
            } else if let exportStatusMessage = model.exportStatusMessage {
                Label(exportStatusMessage, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Export status")
                    .accessibilityValue(exportStatusMessage)
                    .accessibilityIdentifier("settings.diagnostics.exportStatus")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.diagnostics")
        .utterInkAccessibilityAnnouncement(
            model.failureMessage.map { "Error: \($0)" }
                ?? model.exportStatusMessage
        )
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .navigationTitle("Diagnostics")
        .task { await model.refresh() }
        .fileExporter(
            isPresented: $showsExporter,
            document: document,
            contentType: .json,
            defaultFilename: "UtterInk-Diagnostics"
        ) { result in
            model.recordExportResult(result)
            document = nil
        }
    }
}
