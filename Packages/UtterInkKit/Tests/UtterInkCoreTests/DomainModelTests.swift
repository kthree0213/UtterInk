import XCTest
@testable import UtterInkCore

final class DomainModelTests: XCTestCase {
    func testEffectTokenSeparatesGenerationsWithinOneSession() {
        let id = SessionID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        XCTAssertNotEqual(EffectToken(sessionID: id, generation: 1), EffectToken(sessionID: id, generation: 2))
    }

    func testPipelineStartsIdleWithoutParallelFlags() {
        XCTAssertEqual(PipelineState.idle.stage, .idle)
        XCTAssertNil(PipelineState.idle.sessionID)
        XCTAssertNil(PipelineState.idle.result)
    }

    func testPolishFailureResultSelectsRawText() {
        let result = DictationResult(
            sessionID: SessionID(), rawText: "raw", finalText: "raw",
            source: .rawFallback, warning: .polishTransport, delivery: nil
        )
        XCTAssertEqual(result.finalText, result.rawText)
        XCTAssertEqual(result.source, .rawFallback)
    }

    func testDeliveryOutcomeCodableRoundTripPreservesAssociatedDiagnosticCode() throws {
        let outcome = DeliveryOutcome.manualCopyRequired(.deliveryTargetChanged)

        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(DeliveryOutcome.self, from: data)

        XCTAssertEqual(decoded, outcome)
    }

    func testDictationResultCodableRoundTripPreservesExplicitResultValues() throws {
        let result = DictationResult(
            sessionID: SessionID(
                rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            startedAt: Date(timeIntervalSince1970: 1_721_000_000),
            rawText: "raw text",
            finalText: "polished text",
            source: .polished,
            warning: .deliveryPasteboardChanged,
            delivery: .copiedByPreference,
            persistence: .persistent
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(DictationResult.self, from: data)

        XCTAssertEqual(decoded, result)
    }

    func testDiagnosticCodeRawValuesRemainStable() {
        XCTAssertEqual(
            DiagnosticCode.allCases.map(\.rawValue),
            [
                "permission.microphone",
                "permission.accessibility",
                "audio.start",
                "audio.finalize",
                "transcription.empty",
                "transcription.failed",
                "history.write",
                "history.corrupt",
                "credential.missing",
                "credential.migration_conflict",
                "polish.transport",
                "polish.authentication",
                "polish.invalid_response",
                "delivery.target_unavailable",
                "delivery.target_changed",
                "delivery.pasteboard_changed",
                "delivery.dispatch",
                "session.cancelled"
            ]
        )
    }

    func testSpeechModelAndPipelineStatesAreRepresentableIndependently() {
        let pipelineState = PipelineState.idle
        let speechModelState = SpeechModelState.downloading(modelID: "base", progress: 0.25)

        XCTAssertEqual(pipelineState.stage, .idle)
        XCTAssertEqual(speechModelState, .downloading(modelID: "base", progress: 0.25))
    }
}
