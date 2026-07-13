import Foundation
import UtterInkCore

enum EnglishCopy {
    static let appUnavailable = "UtterInk is unavailable. Quit and reopen the app to try again."
    static let cancel = "Cancel"
    static let copyLatestResult = "Copy Latest Result"
    static let dismiss = "Dismiss"
    static let history = "History"
    static let historyUnavailable = "History will be available after its window is installed."
    static let latestResult = "Latest Result"
    static let noRecentResult = "No recent result"
    static let onboarding = "Onboarding"
    static let onboardingUnavailable = "Onboarding will be available after its window is installed."
    static let output = "Output"
    static let outputSaveFailed = "The output mode could not be saved. Your current selection was kept."
    static let pasteLatestResult = "Paste Again"
    static let quit = "Quit UtterInk"
    static let recognitionLanguage = "Recognition Language"
    static let settings = "Settings…"
    static let speechModel = "Speech Model"
    static let start = "Start Listening"
    static let status = "Status"
    static let stop = "Stop Listening"
    static let starting = "Starting UtterInk"
    static let unavailable = "Unavailable"

    static let failedWarning = "Dictation needs attention. Your latest text remains available."
    static let resultWarning = "Completed with a warning"
    static let resultSuccess = "Dictation completed"

    static func warning(for code: DiagnosticCode) -> String {
        switch code {
        case .permissionMicrophone:
            return "Microphone access is required. Review permission in Settings."
        case .permissionAccessibility:
            return "Accessibility is unavailable. Copy the result or enable Accessibility in System Settings."
        case .audioStart:
            return "Recording could not start. Check the input device and try again."
        case .audioFinalize:
            return "Recording could not be finalized. Start a new dictation to try again."
        case .transcriptionEmpty:
            return "No speech was detected. Try speaking closer to the microphone."
        case .transcriptionFailed:
            return "The recording could not be transcribed. Start a new dictation to try again."
        case .historyWrite:
            return "The result is available, but it could not be saved to History."
        case .historyCorrupt:
            return "History could not be read safely. Your latest result remains available."
        case .credentialMissing:
            return "The selected output mode needs a provider key in Settings."
        case .credentialMigrationConflict:
            return "Two provider keys need review in Settings before polishing."
        case .polishTransport:
            return "Polishing could not reach the provider. Raw text remains available."
        case .polishAuthentication:
            return "The provider rejected its key. Raw text remains available."
        case .polishInvalidResponse:
            return "The provider returned unusable text. Raw text was kept."
        case .deliveryTargetUnavailable:
            return "The original target is unavailable. Copy the result to paste it manually."
        case .deliveryTargetChanged:
            return "The original target changed. Copy the result to paste it safely."
        case .deliveryPasteboardChanged:
            return "The clipboard changed during delivery. The result remains available."
        case .deliveryDispatch:
            return "Automatic paste did not complete. Copy the result to paste it manually."
        case .cancelled:
            return "Automation was canceled. Recoverable text remains available."
        }
    }

    static func recognition(_ configuration: RecognitionConfiguration) -> String {
        switch configuration {
        case .automatic:
            return "Automatic"
        case let .fixed(languageCode):
            return languageCode.localizedUppercase
        }
    }

    static func speechModel(_ state: SpeechModelState) -> String {
        switch state {
        case let .missing(modelID):
            return "\(modelID) — Not Downloaded"
        case let .downloading(modelID, progress):
            return "\(modelID) — Downloading \(Int((progress * 100).rounded()))%"
        case let .loading(modelID):
            return "\(modelID) — Loading"
        case let .ready(modelID):
            return "\(modelID) — Ready"
        case let .failed(modelID, _, retryable):
            return retryable
                ? "\(modelID) — Needs Retry"
                : "\(modelID) — Unavailable"
        }
    }
}

enum StagePrimaryAction: Equatable {
    case start
    case stop
    case none
}

enum StageSecondaryAction: Equatable {
    case cancel
    case dismiss
    case none
}

struct StagePresentation: Equatable {
    let label: String
    let systemImage: String
    let primaryAction: StagePrimaryAction
    let canCancel: Bool
    let secondaryAction: StageSecondaryAction
    let accessibilityValue: String
    let warning: String?

    init(stage: PipelineStage, deliveryPreference: DeliveryPreference) {
        self.init(
            stage: stage,
            deliveryPreference: deliveryPreference,
            warningCode: nil
        )
    }

    init(state: PipelineState, deliveryPreference: DeliveryPreference) {
        self.init(
            stage: state.stage,
            deliveryPreference: deliveryPreference,
            warningCode: state.failure?.code ?? state.result?.warning
        )
    }

    init(
        state: PipelineState,
        sessionPresentation: SessionPresentationContext?
    ) {
        if state.stage == .delivering, sessionPresentation == nil {
            let warning = EnglishCopy.warning(for: .deliveryTargetUnavailable)
            self.init(
                label: "Needs Attention",
                systemImage: "exclamationmark.triangle.fill",
                primaryAction: .none,
                canCancel: true,
                secondaryAction: .cancel,
                warning: warning
            )
            return
        }
        if let sessionPresentation {
            self.init(
                state: state,
                deliveryPreference: sessionPresentation.deliveryPreference
            )
        } else {
            // Delivery preference has no effect outside the delivering stage.
            self.init(state: state, deliveryPreference: .copyOnly)
        }
    }

    private init(
        label: String,
        systemImage: String,
        primaryAction: StagePrimaryAction,
        canCancel: Bool,
        secondaryAction: StageSecondaryAction,
        warning: String?
    ) {
        self.label = label
        self.systemImage = systemImage
        self.primaryAction = primaryAction
        self.canCancel = canCancel
        self.secondaryAction = secondaryAction
        self.warning = warning
        accessibilityValue = warning.map { "\(label). \($0)" } ?? label
    }

    private init(
        stage: PipelineStage,
        deliveryPreference: DeliveryPreference,
        warningCode: DiagnosticCode?
    ) {
        let values: (
            label: String,
            systemImage: String,
            primaryAction: StagePrimaryAction,
            canCancel: Bool,
            secondaryAction: StageSecondaryAction
        )

        switch stage {
        case .idle:
            values = ("Ready", "text.cursor", .start, false, .none)
        case .requestingPermission:
            values = (
                "Requesting Permission",
                "hand.raised",
                .none,
                true,
                .cancel
            )
        case .recording:
            values = ("Listening", "clock", .stop, true, .cancel)
        case .stopping:
            values = ("Stopping", "square", .none, true, .cancel)
        case .transcribing:
            values = ("Transcribing", "text.badge.plus", .none, true, .cancel)
        case .polishing:
            values = ("Polishing", "text.badge.checkmark", .none, true, .cancel)
        case .delivering:
            values = (
                deliveryPreference == .automaticPaste ? "Pasting" : "Copying",
                deliveryPreference == .automaticPaste ? "arrow.up.doc" : "doc.on.doc",
                .none,
                true,
                .cancel
            )
        case .completed:
            values = ("Done", "checkmark", .start, false, .dismiss)
        case .failed:
            values = (
                "Needs Attention",
                "exclamationmark.triangle.fill",
                .start,
                false,
                .dismiss
            )
        }

        label = values.label
        systemImage = values.systemImage
        primaryAction = values.primaryAction
        canCancel = values.canCancel
        secondaryAction = values.secondaryAction
        if let warningCode {
            warning = EnglishCopy.warning(for: warningCode)
        } else if stage == .failed {
            warning = EnglishCopy.failedWarning
        } else {
            warning = nil
        }
        accessibilityValue = warning.map { "\(values.label). \($0)" } ?? values.label
    }
}
