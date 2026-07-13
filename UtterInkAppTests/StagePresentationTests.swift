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
        resultWarning: DiagnosticCode? = nil
    ) -> PipelineState {
        let result = resultWarning.map {
            DictationResult(
                sessionID: SessionID(),
                rawText: "raw",
                finalText: "result",
                source: .raw,
                warning: $0,
                delivery: nil
            )
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
