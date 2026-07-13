import Accessibility
import SwiftUI
import UtterInkCore

struct HistoryView: View {
    let model: HistoryViewModel

    @State private var pendingDeletion: RecoveryItem?
    @State private var deleteFocusTarget: SessionID?
    @State private var isConfirmingClear = false
    @FocusState private var focusedDeleteSessionID: SessionID?
    @FocusState private var isClearHistoryFocused: Bool

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
                .accessibilityIdentifier("history.clearAll")
                .focused($isClearHistoryFocused)
                .help("Delete every saved and in-process history result")
            }

            if model.items.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed dictations will appear here when History is enabled.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("history.empty")
            } else {
                List(model.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(
                                item.variantLabel,
                                systemImage: item.source == .polished
                                    ? "text.badge.checkmark"
                                    : "text.quote"
                            )
                            .font(.headline)
                            .accessibilityIdentifier(
                                "history.variant.\(item.sessionID.rawValue.uuidString.lowercased())"
                            )

                            Spacer()

                            Text(
                                item.startedAt,
                                format: .dateTime.month(.abbreviated).day().hour().minute()
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Text(item.preview)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .accessibilityLabel("Result preview")
                            .accessibilityValue(item.preview)
                            .accessibilityIdentifier(
                                "history.preview.\(item.sessionID.rawValue.uuidString.lowercased())"
                            )

                        RecoveryStatusView(item: item)
                        RecoveryActionButtons(
                            item: item,
                            focusedDeleteSessionID: $focusedDeleteSessionID
                        ) { action in
                            if action == .delete {
                                deleteFocusTarget = item.sessionID
                                pendingDeletion = item
                            } else {
                                model.perform(action, sessionID: item.sessionID)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        "history.item.\(item.sessionID.rawValue.uuidString.lowercased())"
                    )
                }
                .listStyle(.inset)
                .accessibilityLabel("Dictation history")
                .accessibilityValue("\(model.items.count) results")
                .accessibilityIdentifier("history.list")
            }

            Label(
                "Turning History off stops new saves. Existing saved records remain until you choose Clear History.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("history.root")
        .onChange(of: model.items.count) { previous, current in
            guard previous != current else { return }
            AccessibilityNotification.Announcement(
                "History updated. \(current) \(current == 1 ? "result" : "results")."
            ).post()
        }
        .sheet(item: $pendingDeletion) { item in
            HistoryConfirmationSheet(
                title: "Delete this history item?",
                message: "This removes the selected result from UtterInk. This action cannot be undone.",
                destructiveTitle: "Delete Item",
                destructiveIdentifier: "history.confirmDelete",
                cancelIdentifier: "history.cancelDelete",
                confirm: {
                    deleteFocusTarget = nil
                    model.perform(.delete, sessionID: item.sessionID)
                    pendingDeletion = nil
                },
                cancel: {
                    cancelDeletion(item)
                }
            )
        }
        .sheet(isPresented: $isConfirmingClear) {
            HistoryConfirmationSheet(
                title: "Clear all history?",
                message: "This immediately cancels any active dictation and removes all saved and in-process results. This action cannot be undone.",
                destructiveTitle: "Clear History",
                destructiveIdentifier: "history.confirmClear",
                cancelIdentifier: "history.cancelClear",
                confirm: {
                    model.perform(.clearAll)
                    isConfirmingClear = false
                },
                cancel: {
                    isConfirmingClear = false
                    returnFocusToClearHistory()
                }
            )
        }
    }

    private func cancelDeletion(_ item: RecoveryItem) {
        deleteFocusTarget = item.sessionID
        pendingDeletion = nil
        returnFocusToDeleteTarget()
    }

    private func returnFocusToDeleteTarget() {
        guard let target = deleteFocusTarget else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            focusedDeleteSessionID = target
        }
    }

    private func returnFocusToClearHistory() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            isClearHistoryFocused = true
        }
    }
}

private struct HistoryConfirmationSheet: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let destructiveIdentifier: String
    let cancelIdentifier: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(cancelIdentifier)
                Button(destructiveTitle, role: .destructive, action: confirm)
                    .accessibilityIdentifier(destructiveIdentifier)
            }
        }
        .padding(24)
        .frame(width: 440)
        .accessibilityElement(children: .contain)
        .interactiveDismissDisabled()
        .onExitCommand(perform: cancel)
    }
}
