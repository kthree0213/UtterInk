import Accessibility
import SwiftUI
import UtterInkCore

struct LastResultView: View {
    let model: HistoryViewModel
    var compact = false

    @State private var pendingDeletion: RecoveryItem?
    @State private var deletionAwaitingAnnouncement: SessionID?
    @FocusState private var focusedDeleteSessionID: SessionID?

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
                            .accessibilityLabel("Result text")
                            .accessibilityValue(item.finalText)
                            .accessibilityIdentifier("lastResult.text")

                        RecoveryStatusView(item: item)
                        RecoveryActionButtons(
                            item: item,
                            focusedDeleteSessionID: $focusedDeleteSessionID
                        ) { action in
                            if action == .delete {
                                pendingDeletion = item
                            } else {
                                model.perform(action, sessionID: item.sessionID)
                            }
                        }
                    }
                    .padding(compact ? 12 : 20)
                }
                .accessibilityIdentifier("lastResult.content")
            } else {
                ContentUnavailableView(
                    EnglishCopy.noRecentResult,
                    systemImage: "text.badge.xmark",
                    description: Text("Complete a dictation to make its result available here.")
                )
                .padding(20)
                .accessibilityIdentifier("lastResult.empty")
            }
        }
        .navigationTitle(EnglishCopy.latestResult)
        .onChange(of: model.items.map(\.sessionID)) { _, currentSessionIDs in
            guard let deletedSessionID = deletionAwaitingAnnouncement,
                  !currentSessionIDs.contains(deletedSessionID) else { return }
            deletionAwaitingAnnouncement = nil
            AccessibilityNotification.Announcement("Result deleted.").post()
        }
        .confirmationDialog(
            "Delete this result?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { isPresented in
                    if !isPresented, let item = pendingDeletion {
                        cancelDeletion(item)
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete Result", role: .destructive) {
                deletionAwaitingAnnouncement = item.sessionID
                model.perform(.delete, sessionID: item.sessionID)
                pendingDeletion = nil
            }
            .accessibilityIdentifier("lastResult.confirmDelete")
            Button("Cancel", role: .cancel) {
                cancelDeletion(item)
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("lastResult.cancelDelete")
        } message: { _ in
            Text("This removes the result from UtterInk. This action cannot be undone.")
        }
    }

    private func sourceImage(for item: RecoveryItem) -> String {
        item.source == .polished ? "text.badge.checkmark" : "text.quote"
    }

    private func cancelDeletion(_ item: RecoveryItem) {
        pendingDeletion = nil
        Task { @MainActor in
            await Task.yield()
            focusedDeleteSessionID = item.sessionID
        }
    }
}

struct RecoveryStatusView: View {
    let item: RecoveryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let delivery = item.deliveryLabel {
                Label(delivery, systemImage: deliveryImage)
                    .font(.caption)
                    .accessibilityLabel("Delivery status")
                    .accessibilityValue(delivery)
                    .accessibilityIdentifier(
                        "recovery.delivery.\(item.sessionID.rawValue.uuidString.lowercased())"
                    )
            }

            ForEach(Array(item.warningLabels.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .accessibilityLabel("Warning")
                    .accessibilityValue(warning)
            }

            if let persistence = item.persistenceLabel {
                Label(persistence, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption)
                    .accessibilityLabel("History status")
                    .accessibilityValue(persistence)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "recovery.status.\(item.sessionID.rawValue.uuidString.lowercased())"
        )
        .onChange(of: accessibilitySummary) { _, summary in
            AccessibilityNotification.Announcement(
                "Result updated. \(summary)"
            ).post()
        }
    }

    private var accessibilitySummary: String {
        ([item.variantLabel, item.deliveryLabel]
            .compactMap { $0 }
            + item.warningLabels
            + [item.persistenceLabel].compactMap { $0 })
            .joined(separator: ". ")
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
    var focusedDeleteSessionID: FocusState<SessionID?>.Binding?
    let perform: (HistoryAction) -> Void

    init(
        item: RecoveryItem,
        focusedDeleteSessionID: FocusState<SessionID?>.Binding? = nil,
        perform: @escaping (HistoryAction) -> Void
    ) {
        self.item = item
        self.focusedDeleteSessionID = focusedDeleteSessionID
        self.perform = perform
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                actionButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(item.supportedActions, id: \.self) { action in
            Button(role: action == .delete ? .destructive : nil) {
                perform(action)
                AccessibilityNotification.Announcement(
                    action == .delete
                        ? "Delete confirmation opened."
                        : "\(action.label) requested."
                ).post()
            } label: {
                Label(action.label, systemImage: action.systemImage)
            }
            .accessibilityLabel(action.label)
            .accessibilityIdentifier(
                "recovery.\(accessibilityName(for: action)).\(item.sessionID.rawValue.uuidString.lowercased())"
            )
            .modifier(DeleteActionFocusModifier(
                action: action,
                sessionID: item.sessionID,
                focusedSessionID: focusedDeleteSessionID
            ))
            .help(action.label)
        }
    }

    private func accessibilityName(for action: HistoryAction) -> String {
        switch action {
        case .copy: return "copy"
        case .pasteAgain: return "pasteAgain"
        case .retryPolishing: return "retryPolishing"
        case .delete: return "delete"
        case .clearAll: return "clearAll"
        }
    }
}

private struct DeleteActionFocusModifier: ViewModifier {
    let action: HistoryAction
    let sessionID: SessionID
    let focusedSessionID: FocusState<SessionID?>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if action == .delete, let focusedSessionID {
            content.focused(focusedSessionID, equals: sessionID)
        } else {
            content
        }
    }
}
