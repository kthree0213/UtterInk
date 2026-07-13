import SwiftUI

struct LastResultView: View {
    let model: HistoryViewModel
    var compact = false

    @State private var pendingDeletion: RecoveryItem?

    var body: some View {
        Group {
            if let item = model.latestItem {
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(item.variantLabel, systemImage: sourceImage(for: item))
                                .font(.headline)
                            Spacer()
                            Text(item.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(item.finalText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .lineLimit(compact ? 8 : nil)

                        RecoveryStatusView(item: item)
                        RecoveryActionButtons(item: item) { action in
                            if action == .delete {
                                pendingDeletion = item
                            } else {
                                model.perform(action, sessionID: item.sessionID)
                            }
                        }
                    }
                    .padding(compact ? 12 : 20)
                }
            } else {
                ContentUnavailableView(
                    EnglishCopy.noRecentResult,
                    systemImage: "text.badge.xmark",
                    description: Text("Complete a dictation to make its result available here.")
                )
                .padding(20)
            }
        }
        .navigationTitle(EnglishCopy.latestResult)
        .confirmationDialog(
            "Delete this result?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete Result", role: .destructive) {
                model.perform(.delete, sessionID: item.sessionID)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("This removes the result from UtterInk. This action cannot be undone.")
        }
    }

    private func sourceImage(for item: RecoveryItem) -> String {
        item.source == .polished ? "text.badge.checkmark" : "text.quote"
    }
}

struct RecoveryStatusView: View {
    let item: RecoveryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let delivery = item.deliveryLabel {
                Label(delivery, systemImage: deliveryImage)
                    .font(.caption)
            }

            ForEach(Array(item.warningLabels.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
            }

            if let persistence = item.persistenceLabel {
                Label(persistence, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
            }
        }
    }

    private var deliveryImage: String {
        switch item.delivery {
        case .pasteEventDispatched: return "keyboard"
        case .deliveredToOnboardingTest: return "checkmark.circle"
        case .copiedByPreference, .copiedByUser: return "doc.on.clipboard"
        case .manualCopyRequired: return "hand.raised"
        case nil: return "circle"
        }
    }
}

struct RecoveryActionButtons: View {
    let item: RecoveryItem
    let perform: (HistoryAction) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(item.supportedActions, id: \.self) { action in
            Button(role: action == .delete ? .destructive : nil) {
                perform(action)
            } label: {
                Label(action.label, systemImage: action.systemImage)
            }
            .help(action.label)
        }
    }
}
