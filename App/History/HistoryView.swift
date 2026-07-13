import SwiftUI

struct HistoryView: View {
    let model: HistoryViewModel

    @State private var pendingDeletion: RecoveryItem?
    @State private var isConfirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(EnglishCopy.history)
                        .font(.title2.bold())
                    Text("Newest 20 original sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    isConfirmingClear = true
                } label: {
                    Label(HistoryAction.clearAll.label, systemImage: HistoryAction.clearAll.systemImage)
                }
                .help("Delete every saved and in-process history result")
            }

            if model.items.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed dictations will appear here when History is enabled.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(
                                item.variantLabel,
                                systemImage: item.source == .polished ? "text.badge.checkmark" : "text.quote"
                            )
                            .font(.headline)

                            Spacer()

                            Text(item.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(item.preview)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        RecoveryStatusView(item: item)
                        RecoveryActionButtons(item: item) { action in
                            if action == .delete {
                                pendingDeletion = item
                            } else {
                                model.perform(action, sessionID: item.sessionID)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }

            Label(
                "Turning History off stops new saves. Existing saved records remain until you choose Clear History.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .confirmationDialog(
            "Delete this history item?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete Item", role: .destructive) {
                model.perform(.delete, sessionID: item.sessionID)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This removes the selected result from UtterInk. This action cannot be undone.")
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                model.perform(.clearAll)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This immediately cancels any active dictation and removes all saved and in-process results. This action cannot be undone.")
        }
    }
}
