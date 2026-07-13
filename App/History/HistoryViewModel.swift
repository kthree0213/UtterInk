import Foundation
import UtterInkCore

enum AppWindowID {
    static let history = "history"
    static let lastResult = "last-result"
}

enum HistoryAction: Equatable, Hashable, CaseIterable {
    case copy
    case pasteAgain
    case retryPolishing
    case delete
    case clearAll

    var label: String {
        switch self {
        case .copy: return "Copy"
        case .pasteAgain: return "Paste Again"
        case .retryPolishing: return "Retry Polishing"
        case .delete: return "Delete"
        case .clearAll: return "Clear History"
        }
    }

    var systemImage: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .pasteAgain: return "arrow.up.doc"
        case .retryPolishing: return "arrow.clockwise"
        case .delete: return "trash"
        case .clearAll: return "trash.slash"
        }
    }
}

struct RecoveryItem: Identifiable, Equatable {
    static let previewCharacterLimit = 240

    var id: SessionID { sessionID }

    let sessionID: SessionID
    let startedAt: Date
    let rawText: String
    let finalText: String
    let source: ResultSource
    let warning: DiagnosticCode?
    let delivery: DeliveryOutcome?
    let persistence: ResultPersistence
    let outcome: HistoryOutcome?

    var variantLabel: String {
        source == .polished ? "Polished" : "Raw"
    }

    var preview: String {
        let normalized = finalText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > Self.previewCharacterLimit else { return normalized }
        return String(normalized.prefix(Self.previewCharacterLimit - 1)) + "…"
    }

    var warningLabel: String? {
        warning.map(EnglishCopy.warning(for:))
    }

    var deliveryWarningLabel: String? {
        guard case let .manualCopyRequired(code) = delivery else { return nil }
        return EnglishCopy.warning(for: code)
    }

    var warningLabels: [String] {
        [warningLabel, deliveryWarningLabel]
            .compactMap { $0 }
            .reduce(into: []) { labels, label in
                if !labels.contains(label) {
                    labels.append(label)
                }
            }
    }

    var deliveryLabel: String? {
        switch delivery {
        case .pasteEventDispatched:
            return "Paste event sent"
        case .deliveredToOnboardingTest:
            return "Sent to Onboarding Test"
        case .copiedByPreference:
            return "Copied to Clipboard (Copy Only)"
        case .copiedByUser:
            return "Copied by You"
        case .manualCopyRequired:
            return "Manual copy required"
        case nil:
            return nil
        }
    }

    var persistenceLabel: String? {
        persistence == .volatile
            ? "Not saved — disappears when UtterInk quits"
            : nil
    }

    var supportedActions: [HistoryAction] {
        var actions: [HistoryAction] = []
        if !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions += [.copy, .pasteAgain]
        }
        if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.append(.retryPolishing)
        }
        actions.append(.delete)
        return actions
    }
}

@MainActor
final class HistoryViewModel {
    private let controller: any DictationControlling

    init(controller: any DictationControlling) {
        self.controller = controller
    }

    var items: [RecoveryItem] {
        var persistent: [SessionID: HistoryRecord] = [:]
        for record in controller.historyRecords {
            if let current = persistent[record.sessionID] {
                if record.startedAt > current.startedAt {
                    persistent[record.sessionID] = record
                }
            } else {
                persistent[record.sessionID] = record
            }
        }

        var volatile: [SessionID: DictationResult] = [:]
        for result in controller.volatileResults where volatile[result.sessionID] == nil {
            volatile[result.sessionID] = result
        }

        var merged: [RecoveryItem] = persistent.values.map { record in
            guard let current = volatile.removeValue(forKey: record.sessionID) else {
                return RecoveryItem(
                    sessionID: record.sessionID,
                    startedAt: record.startedAt,
                    rawText: record.rawText,
                    finalText: record.finalText ?? record.rawText,
                    source: record.source,
                    warning: record.warning,
                    delivery: record.delivery,
                    persistence: .persistent,
                    outcome: record.outcome
                )
            }
            return RecoveryItem(
                sessionID: record.sessionID,
                startedAt: record.startedAt,
                rawText: record.rawText,
                finalText: current.finalText,
                source: current.source,
                warning: current.warning,
                delivery: current.delivery,
                persistence: .persistent,
                outcome: record.outcome
            )
        }

        merged += volatile.values.map { result in
            RecoveryItem(
                sessionID: result.sessionID,
                startedAt: result.startedAt,
                rawText: result.rawText,
                finalText: result.finalText,
                source: result.source,
                warning: result.warning,
                delivery: result.delivery,
                persistence: result.persistence,
                outcome: nil
            )
        }

        return Array(
            merged.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt > rhs.startedAt
                }
                return lhs.sessionID.rawValue.uuidString
                    < rhs.sessionID.rawValue.uuidString
            }.prefix(20)
        )
    }

    var latestItem: RecoveryItem? { items.first }

    func perform(_ action: HistoryAction, sessionID: SessionID) {
        switch action {
        case .copy:
            controller.send(.copyResult(sessionID))
        case .pasteAgain:
            controller.send(.pasteAgain(sessionID))
        case .retryPolishing:
            controller.send(.retryPolishing(sessionID))
        case .delete:
            controller.send(.deleteResult(sessionID))
        case .clearAll:
            controller.send(.clearHistory)
        }
    }

    func perform(_ action: HistoryAction) {
        guard action == .clearAll else { return }
        controller.send(.clearHistory)
    }
}
