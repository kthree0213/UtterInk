import SwiftUI

struct SpeechModelSettingsView: View {
    @Bindable var model: SpeechModelSettingsViewModel

    var body: some View {
        Form {
            Section("Presets") {
                ForEach(model.presets) { option in
                    modelRow(option)
                }
            }

            if !model.advanced.isEmpty {
                Section("Advanced") {
                    ForEach(model.advanced) { option in
                        modelRow(option)
                    }
                }
            }

            Section("Readiness") {
                Text(model.presentation.title)
                    .font(.headline)
                    .accessibilityLabel("Speech model status")
                    .accessibilityValue(model.presentation.title)
                    .accessibilityIdentifier("settings.speechModel.status")
                    .accessibilityAddTraits(.updatesFrequently)
                Text(model.presentation.detail)
                    .foregroundStyle(.secondary)
                if let progress = model.presentation.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel("Speech model preparation progress")
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                        .accessibilityIdentifier("settings.speechModel.progress")
                }
                HStack {
                    if model.presentation.canRetry {
                        Button("Retry") { model.retry() }
                            .accessibilityIdentifier("settings.speechModel.retry")
                    }
                    if model.presentation.canCancel {
                        Button("Cancel") { model.cancel() }
                            .accessibilityIdentifier("settings.speechModel.cancel")
                    }
                }
            }
            .accessibilityIdentifier("settings.speechModel.readiness")

            if let cacheActionMessage = model.cacheActionMessage {
                Label(
                    cacheActionMessage,
                    systemImage: model.cacheActionFailed
                        ? "exclamationmark.triangle.fill"
                        : (model.cacheActionIsPending ? "hourglass" : "checkmark.circle")
                )
                .foregroundStyle(model.cacheActionFailed ? .red : .secondary)
                .accessibilityLabel(model.cacheActionFailed ? "Error" : "Model cache status")
                .accessibilityValue(cacheActionMessage)
                .accessibilityIdentifier("settings.speechModel.cacheStatus")
                .accessibilityAddTraits(.updatesFrequently)
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: model.failureSymbol)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error")
                    .accessibilityValue(failureMessage)
                    .accessibilityIdentifier("settings.speechModel.error")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.speechModel")
        .utterInkAccessibilityAnnouncement(
            model.failureMessage.map { "Error: \($0)" }
                ?? model.cacheActionMessage
                ?? "Speech model status: \(model.presentation.title)"
        )
        .utterInkAccessibilityAnnouncement(model.accessibilityEvent)
        .navigationTitle("Speech Model")
        .task { await model.load() }
        .alert(
            "Download Speech Model?",
            isPresented: Binding(
                get: { model.pendingDownload != nil },
                set: { if !$0 { model.cancelDownload() } }
            ),
            presenting: model.pendingDownload
        ) { _ in
            Button("Download") {
                Task { await model.confirmDownload() }
            }
            .accessibilityIdentifier("settings.speechModel.confirmDownload")
            Button("Cancel", role: .cancel) { model.cancelDownload() }
                .accessibilityIdentifier("settings.speechModel.cancelDownload")
        } message: { option in
            Text(
                "Download \(option.title) to this Mac? The download is approximately \(option.diskImpact). Your current model will remain unchanged unless you confirm."
            )
        }
        .alert(
            "Delete Cached Model?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            ),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmDeletion() }
                .accessibilityIdentifier("settings.speechModel.confirmDelete")
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
                .accessibilityIdentifier("settings.speechModel.cancelDelete")
        } message: { option in
            Text("Delete the cached \(option.title) model (\(option.diskImpact)) from this Mac?")
        }
    }

    private func modelRow(_ option: SpeechModelOption) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.select(option.id) }
            } label: {
                Image(systemName: model.selectedModelID == option.id
                    ? "largecircle.fill.circle"
                    : "circle")
            }
            .buttonStyle(.plain)
            .disabled(model.isSaving || model.cacheActionIsPending)
            .accessibilityLabel(option.isRecommended
                ? "Select \(option.title), recommended"
                : "Select \(option.title)")
            .accessibilityValue(model.selectedModelID == option.id ? "Selected" : "Not selected")
            .accessibilityIdentifier("settings.speechModel.select.\(option.id)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(option.title)
                    if option.isRecommended {
                        SpeechModelRecommendationBadge()
                            .accessibilityIdentifier("settings.speechModel.recommended.\(option.id)")
                    }
                }
                Text("Model ID: \(option.id) · Disk impact: \(option.diskImpact)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isDownloaded(option.id) {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("settings.speechModel.downloaded.\(option.id)")
            }
            Button {
                model.requestDeletion(option.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canDelete(option.id))
            .help(model.canDelete(option.id)
                ? "Delete cached model"
                : "Selected, active, or preparing models cannot be deleted")
            .accessibilityLabel("Delete cached \(option.title) model")
            .accessibilityIdentifier("settings.speechModel.delete.\(option.id)")
        }
    }
}

struct SpeechModelRecommendationBadge: View {
    var body: some View {
        Text("Recommended")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .accessibilityLabel("Recommended model")
    }
}
