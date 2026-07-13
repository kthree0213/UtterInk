import XCTest
import UtterInkCore
@testable import UtterInk

final class StagePresentationTests: XCTestCase {
    func testEveryStageHasSpecificAccessibleCopy() {
        let expected: [PipelineStage: String] = [
            .idle: "Ready",
            .requestingPermission: "Requesting Permission",
            .recording: "Listening",
            .stopping: "Stopping",
            .transcribing: "Transcribing",
            .polishing: "Polishing",
            .delivering: "Pasting",
            .completed: "Done",
            .failed: "Needs Attention",
        ]

        for (stage, label) in expected {
            XCTAssertEqual(
                StagePresentation(
                    stage: stage,
                    deliveryPreference: .automaticPaste
                ).label,
                label
            )
        }
        XCTAssertEqual(
            StagePresentation(
                stage: .delivering,
                deliveryPreference: .copyOnly
            ).label,
            "Copying"
        )
    }

    func testActionsAndCancellationFollowTheStateContract() {
        let activeStages: [PipelineStage] = [
            .requestingPermission,
            .recording,
            .stopping,
            .transcribing,
            .polishing,
            .delivering,
        ]

        for stage in activeStages {
            let presentation = StagePresentation(
                stage: stage,
                deliveryPreference: .automaticPaste
            )
            XCTAssertTrue(presentation.canCancel, "Expected cancel for \(stage)")
            XCTAssertEqual(presentation.secondaryAction, .cancel)
        }

        XCTAssertEqual(presentation(for: .idle).primaryAction, .start)
        XCTAssertEqual(presentation(for: .recording).primaryAction, .stop)
        XCTAssertEqual(presentation(for: .transcribing).primaryAction, .none)

        for stage in [PipelineStage.completed, .failed] {
            let presentation = presentation(for: stage)
            XCTAssertFalse(presentation.canCancel)
            XCTAssertEqual(presentation.secondaryAction, .dismiss)
            XCTAssertEqual(presentation.primaryAction, .start)
        }
    }

    func testSymbolsAvoidRejectedVisualMotifsAndAccessibilityCopyIsNeverEmpty() {
        let rejectedFragments = ["mic", "waveform", "bubble", "drop", "quill", "sparkle"]

        for stage in allStages {
            let presentation = presentation(for: stage)
            XCTAssertFalse(presentation.systemImage.isEmpty)
            XCTAssertFalse(presentation.accessibilityValue.isEmpty)
            for fragment in rejectedFragments {
                XCTAssertFalse(
                    presentation.systemImage.localizedCaseInsensitiveContains(fragment),
                    "\(stage) uses rejected motif \(fragment)"
                )
            }
        }
    }

    func testFailureAndResultWarningsUseSpecificDiagnosticCopy() {
        let microphone = StagePresentation(
            state: state(stage: .failed, failure: .permissionMicrophone),
            deliveryPreference: .automaticPaste
        )
        let transcription = StagePresentation(
            state: state(stage: .failed, failure: .transcriptionFailed),
            deliveryPreference: .automaticPaste
        )
        let resultWarning = StagePresentation(
            state: state(stage: .completed, resultWarning: .historyWrite),
            deliveryPreference: .automaticPaste
        )

        XCTAssertNotEqual(microphone.warning, transcription.warning)
        XCTAssertEqual(microphone.warning, EnglishCopy.warning(for: .permissionMicrophone))
        XCTAssertEqual(resultWarning.warning, EnglishCopy.warning(for: .historyWrite))
        XCTAssertTrue(microphone.accessibilityValue.contains(microphone.warning!))
    }

    func testCompletedManualCopyRequirementUsesSpecificDeliveryWarning() {
        let presentation = StagePresentation(
            state: state(
                stage: .completed,
                delivery: .manualCopyRequired(.deliveryTargetChanged)
            ),
            deliveryPreference: .automaticPaste
        )

        XCTAssertEqual(presentation.label, "Done")
        XCTAssertEqual(
            presentation.warning,
            EnglishCopy.warning(for: .deliveryTargetChanged)
        )
        XCTAssertTrue(
            presentation.accessibilityValue.contains(
                EnglishCopy.warning(for: .deliveryTargetChanged)
            )
        )
    }

    func testDeliveringFailsClosedWithoutSnapshottedPresentationContext() {
        let missingSnapshot = StagePresentation(
            state: state(stage: .delivering),
            sessionPresentation: nil
        )
        let copiedSnapshot = StagePresentation(
            state: state(stage: .delivering),
            sessionPresentation: SessionPresentationContext(deliveryPreference: .copyOnly)
        )

        XCTAssertEqual(missingSnapshot.label, "Needs Attention")
        XCTAssertNotEqual(missingSnapshot.label, "Pasting")
        XCTAssertNotEqual(missingSnapshot.label, "Copying")
        XCTAssertEqual(
            missingSnapshot.warning,
            EnglishCopy.warning(for: .deliveryTargetUnavailable)
        )
        XCTAssertEqual(copiedSnapshot.label, "Copying")
    }

    func testOnboardingDeliveryIsNeverPresentedAsPasteOrClipboardMutation() {
        let onboarding = StagePresentation(
            state: state(stage: .delivering),
            sessionPresentation: SessionPresentationContext(
                deliveryPreference: .automaticPaste,
                destination: .onboardingTest
            )
        )

        XCTAssertEqual(onboarding.label, "Returning Result to Onboarding")
        XCTAssertEqual(onboarding.accessibilityValue, "Returning Result to Onboarding")
        XCTAssertNotEqual(onboarding.label, "Pasting")
        XCTAssertNotEqual(onboarding.label, "Copying")
        XCTAssertTrue(onboarding.canCancel)
    }

    func testAutomaticPasteWithoutExternalTargetPresentsNeedsAttention() {
        let fallback = StagePresentation(
            state: state(stage: .delivering),
            sessionPresentation: SessionPresentationContext(
                deliveryPreference: .automaticPaste,
                destination: .copyOnlyFallback
            )
        )

        XCTAssertEqual(fallback.label, "Needs Attention")
        XCTAssertEqual(
            fallback.warning,
            EnglishCopy.warning(for: .deliveryTargetUnavailable)
        )
        XCTAssertNotEqual(fallback.label, "Pasting")
        XCTAssertNotEqual(fallback.label, "Copying")
        XCTAssertTrue(fallback.canCancel)
    }

    func testCopyOnlyPreferenceStillPresentsCopyingWithoutExternalTarget() {
        let fallback = StagePresentation(
            state: state(stage: .delivering),
            sessionPresentation: SessionPresentationContext(
                deliveryPreference: .copyOnly,
                destination: .copyOnlyFallback
            )
        )

        XCTAssertEqual(fallback.label, "Copying")
        XCTAssertNil(fallback.warning)
        XCTAssertTrue(fallback.canCancel)
    }

    func testMenuBarStatusAnnouncementUsesSanitizedResultMetadata() {
        let secretTranscript = "never announce this transcript"
        let result = DictationResult(
            sessionID: SessionID(),
            rawText: secretTranscript,
            finalText: secretTranscript,
            source: .rawFallback,
            warning: .polishTransport,
            delivery: .copiedByUser
        )
        let state = PipelineState(
            stage: .completed,
            sessionID: result.sessionID,
            token: nil,
            result: result,
            failure: nil
        )
        let status = MenuBarStatusAccessibilityPresentation(
            readiness: .ready,
            state: state,
            sessionPresentation: SessionPresentationContext(
                deliveryPreference: .automaticPaste
            )
        )

        XCTAssertEqual(
            status.value,
            "Done. \(EnglishCopy.warning(for: .polishTransport)). Raw fallback result. Copied by you"
        )
        XCTAssertEqual(status.announcement, "Status: \(status.value)")
        XCTAssertFalse(status.announcement.contains(secretTranscript))
    }

    func testMenuBarStatusAnnouncementUsesSpecificSanitizedDeliveryWarning() {
        let secretTranscript = "never announce this delivery transcript"
        let result = DictationResult(
            sessionID: SessionID(),
            rawText: secretTranscript,
            finalText: secretTranscript,
            source: .raw,
            warning: nil,
            delivery: .manualCopyRequired(.deliveryTargetChanged)
        )
        let state = PipelineState(
            stage: .completed,
            sessionID: result.sessionID,
            token: nil,
            result: result,
            failure: nil
        )
        let status = MenuBarStatusAccessibilityPresentation(
            readiness: .ready,
            state: state,
            sessionPresentation: SessionPresentationContext(
                deliveryPreference: .automaticPaste
            )
        )

        XCTAssertEqual(
            status.value,
            "Done. \(EnglishCopy.warning(for: .deliveryTargetChanged)). Raw result. Manual copy required"
        )
        XCTAssertEqual(status.announcement, "Status: \(status.value)")
        XCTAssertFalse(status.announcement.contains(secretTranscript))
    }

    func testMenuBarStatusAnnouncementPreservesExactFailurePresentation() {
        let state = PipelineState(
            stage: .failed,
            sessionID: nil,
            token: nil,
            result: nil,
            failure: PipelineFailure(
                code: .permissionMicrophone,
                recoverableResult: nil
            )
        )
        let stage = StagePresentation(
            state: state,
            sessionPresentation: nil
        )
        let status = MenuBarStatusAccessibilityPresentation(
            readiness: .ready,
            state: state,
            sessionPresentation: nil
        )

        XCTAssertEqual(status.value, stage.accessibilityValue)
    }

    private var allStages: [PipelineStage] {
        [
            .idle,
            .requestingPermission,
            .recording,
            .stopping,
            .transcribing,
            .polishing,
            .delivering,
            .completed,
            .failed,
        ]
    }

    private func presentation(for stage: PipelineStage) -> StagePresentation {
        StagePresentation(stage: stage, deliveryPreference: .automaticPaste)
    }

    private func state(
        stage: PipelineStage,
        failure: DiagnosticCode? = nil,
        resultWarning: DiagnosticCode? = nil,
        delivery: DeliveryOutcome? = nil
    ) -> PipelineState {
        let result: DictationResult? = if resultWarning != nil || delivery != nil {
            DictationResult(
                sessionID: SessionID(),
                rawText: "raw",
                finalText: "result",
                source: .raw,
                warning: resultWarning,
                delivery: delivery
            )
        } else {
            nil
        }
        return PipelineState(
            stage: stage,
            sessionID: nil,
            token: nil,
            result: result,
            failure: failure.map { PipelineFailure(code: $0, recoverableResult: result) }
        )
    }
}
