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
                Text(model.presentation.detail)
                    .foregroundStyle(.secondary)
                if let progress = model.presentation.progress {
                    ProgressView(value: progress)
                        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                }
                HStack {
                    if model.presentation.canRetry {
                        Button("Retry") { model.retry() }
                    }
                    if model.presentation.canCancel {
                        Button("Cancel") { model.cancel() }
                    }
                }
            }

            if let cacheActionMessage = model.cacheActionMessage {
                Label(
                    cacheActionMessage,
                    systemImage: model.cacheActionFailed
                        ? "exclamationmark.triangle.fill"
                        : (model.cacheActionIsPending ? "hourglass" : "checkmark.circle")
                )
                .foregroundStyle(model.cacheActionFailed ? .red : .secondary)
            }

            if let failureMessage = model.failureMessage {
                Label(failureMessage, systemImage: model.failureSymbol)
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Speech Model")
        .task { await model.load() }
        .alert(
            "Delete Cached Model?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.cancelDeletion() } }
            ),
            presenting: model.pendingDeletion
        ) { _ in
            Button("Delete", role: .destructive) { model.confirmDeletion() }
            Button("Cancel", role: .cancel) { model.cancelDeletion() }
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
            .accessibilityLabel("Select \(option.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                Text("Model ID: \(option.id) · Disk impact: \(option.diskImpact)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
        }
    }
}
