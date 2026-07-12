import XCTest
@testable import UtterInkCore

final class DictationReducerTests: XCTestCase {
    private let snapshot = SessionSnapshot(
        id: SessionID(),
        startedAt: Date(timeIntervalSince1970: 1_721_000_000),
        target: .copyOnly,
        recognition: .fixed(languageCode: "en"),
        speechModelID: "small",
        outputMode: OutputMode(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            title: "Polish",
            skipsPolishing: false,
            instructions: "clean"
        ),
        provider: nil,
        historyGeneration: 1,
        historyEnabled: true,
        deliveryPreference: .copyOnly,
        credential: nil
    )

    func testTranscriptionPersistsRawBeforePolishing() {
        let token = EffectToken(sessionID: snapshot.id, generation: 4)
        let state = PipelineState(
            stage: .transcribing,
            sessionID: snapshot.id,
            token: token,
            result: nil,
            failure: nil
        )

        let reduction = DictationReducer.reduce(
            state: state,
            intent: .transcriptionSucceeded(" raw "),
            context: .polishing
        )

        XCTAssertEqual(reduction.state.result?.rawText, "raw")
        XCTAssertEqual(reduction.effects.map(\.kind), [.persistRaw])
    }

    func testCancelAfterRawNeverDelivers() {
        let token = EffectToken(sessionID: snapshot.id, generation: 8)
        let result = DictationResult(
            sessionID: snapshot.id,
            startedAt: snapshot.startedAt,
            rawText: "raw",
            finalText: "raw",
            source: .raw,
            warning: nil,
            delivery: nil
        )
        let state = PipelineState(
            stage: .polishing,
            sessionID: snapshot.id,
            token: token,
            result: result,
            failure: nil
        )

        let reduction = DictationReducer.reduce(
            state: state,
            intent: .cancel,
            context: .polishing
        )

        XCTAssertEqual(reduction.state.stage, .completed)
        XCTAssertEqual(reduction.state.result?.warning, .cancelled)
        XCTAssertFalse(reduction.effects.contains { $0.kind == .deliver })
    }

    func testStartPermissionRecordingAndAudioTransitionTable() {
        let runtimeContext = ReducerContext.runtime(snapshot: snapshot, startToken: token)
        let staleResult = makeResult(
            rawText: "stale raw",
            finalText: "stale final",
            source: .polished,
            warning: .deliveryDispatch,
            delivery: .copiedByUser,
            persistence: .persistent
        )
        let expectedStartState = PipelineState(
            stage: .requestingPermission,
            sessionID: snapshot.id,
            token: token,
            result: nil,
            failure: nil
        )
        let startStates = [
            PipelineState.idle,
            PipelineState(
                stage: .completed,
                sessionID: snapshot.id,
                token: token,
                result: staleResult,
                failure: nil
            ),
            PipelineState(
                stage: .failed,
                sessionID: snapshot.id,
                token: token,
                result: staleResult,
                failure: PipelineFailure(code: .audioStart, recoverableResult: staleResult)
            )
        ]

        for (index, state) in startStates.enumerated() {
            assertTransition(
                name: "start from terminal index \(index)",
                state: state,
                intent: .start(snapshot),
                context: runtimeContext,
                expectedState: expectedStartState,
                expectedEffects: [expectedEffect(.requestMicrophone)]
            )
        }

        let requesting = activeState(stage: .requestingPermission)
        let granted = TransitionFixture(
            name: "permission granted",
            state: requesting,
            intent: .microphoneResolved(.granted),
            context: runtimeContext,
            expectedState: requesting,
            expectedEffects: [expectedEffect(.startRecording)]
        )
        let deniedCodes: [(PermissionState, String)] = [
            (.denied, "permission denied"),
            (.notDetermined, "permission not determined")
        ]
        var permissionFixtures = [granted]
        permissionFixtures.append(contentsOf: deniedCodes.map { permission, name in
            TransitionFixture(
                name: name,
                state: requesting,
                intent: .microphoneResolved(permission),
                context: runtimeContext,
                expectedState: failedState(code: .permissionMicrophone),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        })
        assertTransitions(permissionFixtures)

        let handle = RecordingHandle(
            rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        )
        let staleFailure = PipelineFailure(code: .transcriptionFailed, recoverableResult: staleResult)
        let requestWithStaleTerminalData = activeState(
            stage: .requestingPermission,
            result: staleResult,
            failure: staleFailure
        )
        assertTransitions([
            TransitionFixture(
                name: "recording started without retaining handle in reducer state",
                state: requesting,
                intent: .recordingStarted(handle),
                context: runtimeContext,
                expectedState: activeState(stage: .recording),
                expectedEffects: []
            ),
            TransitionFixture(
                name: "recording start failed and clears stale recoverable data",
                state: requestWithStaleTerminalData,
                intent: .recordingStartFailed(.audioStart),
                context: runtimeContext,
                expectedState: failedState(code: .audioStart),
                expectedEffects: [expectedEffect(.cleanup)]
            ),
            TransitionFixture(
                name: "stop uses controller-owned handle resolution",
                state: activeState(stage: .recording),
                intent: .stopRequested,
                context: runtimeContext,
                expectedState: activeState(stage: .stopping),
                expectedEffects: [expectedEffect(.stopRecording)]
            ),
            TransitionFixture(
                name: "audio finalized",
                state: activeState(stage: .stopping),
                intent: .audioFinalized(audioURL),
                context: runtimeContext,
                expectedState: activeState(stage: .transcribing),
                expectedEffects: [expectedEffect(.transcribe, payload: .audio(audioURL))]
            ),
            TransitionFixture(
                name: "audio finalization failed",
                state: activeState(stage: .stopping),
                intent: .audioFinalizationFailed(.audioFinalize),
                context: runtimeContext,
                expectedState: failedState(code: .audioFinalize),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        ])
    }

    func testStartTokenSelectionIsDeterministicAndNeverUsesHistoryGeneration() {
        let highHistorySnapshot = makeSnapshot(historyGeneration: 999)
        let preferred = EffectToken(sessionID: highHistorySnapshot.id, generation: 7)
        let preferredContext = ReducerContext.runtime(
            snapshot: highHistorySnapshot,
            startToken: preferred
        )
        let preferredReduction = DictationReducer.reduce(
            state: .idle,
            intent: .start(highHistorySnapshot),
            context: preferredContext
        )
        XCTAssertEqual(preferredReduction.state.token, preferred)

        let stateToken = EffectToken(sessionID: highHistorySnapshot.id, generation: 12)
        let wrongContextToken = EffectToken(sessionID: SessionID(), generation: 88)
        let terminal = PipelineState(
            stage: .completed,
            sessionID: highHistorySnapshot.id,
            token: stateToken,
            result: nil,
            failure: nil
        )
        let stateFallback = DictationReducer.reduce(
            state: terminal,
            intent: .start(highHistorySnapshot),
            context: .runtime(snapshot: highHistorySnapshot, startToken: wrongContextToken)
        )
        XCTAssertEqual(stateFallback.state.token, stateToken)

        let deterministicFallback = DictationReducer.reduce(
            state: .idle,
            intent: .start(highHistorySnapshot),
            context: .raw
        )
        XCTAssertEqual(
            deterministicFallback.state.token,
            EffectToken(sessionID: highHistorySnapshot.id, generation: 0)
        )
        XCTAssertNotEqual(deterministicFallback.state.token?.generation, highHistorySnapshot.historyGeneration)
    }

    func testTranscriptionTransitionTable() {
        let runtimeContext = ReducerContext.runtime(snapshot: snapshot, startToken: token)
        let rawResult = makeResult(rawText: "raw", finalText: "raw", source: .raw)
        let persistentRaw = replacing(rawResult, persistence: .persistent)
        let transcribing = activeState(stage: .transcribing)
        let rawState = activeState(stage: .transcribing, result: rawResult)

        assertTransitions([
            TransitionFixture(
                name: "history raw transcript persists before raw delivery",
                state: transcribing,
                intent: .transcriptionSucceeded(" \n raw \t"),
                context: .runtime(snapshot: makeSnapshot(skipsPolishing: true), startToken: token),
                expectedState: rawState,
                expectedEffects: [expectedEffect(.persistRaw, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "history polished transcript persists before polish",
                state: transcribing,
                intent: .transcriptionSucceeded(" raw "),
                context: runtimeContext,
                expectedState: rawState,
                expectedEffects: [expectedEffect(.persistRaw, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "no-history raw transcript delivers immediately",
                state: transcribing,
                intent: .transcriptionSucceeded(" raw "),
                context: .runtime(
                    snapshot: makeSnapshot(skipsPolishing: true, historyEnabled: false),
                    startToken: token
                ),
                expectedState: activeState(stage: .delivering, result: rawResult),
                expectedEffects: [expectedEffect(.deliver, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "no-history polished transcript polishes immediately",
                state: transcribing,
                intent: .transcriptionSucceeded(" raw "),
                context: .runtime(
                    snapshot: makeSnapshot(skipsPolishing: false, historyEnabled: false),
                    startToken: token
                ),
                expectedState: activeState(stage: .polishing, result: rawResult),
                expectedEffects: [expectedEffect(.polish, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "empty transcript fails with sanitized empty code",
                state: transcribing,
                intent: .transcriptionSucceeded(" \n\t "),
                context: runtimeContext,
                expectedState: failedState(code: .transcriptionEmpty),
                expectedEffects: [expectedEffect(.cleanup)]
            ),
            TransitionFixture(
                name: "transcription service failure",
                state: transcribing,
                intent: .transcriptionFailed(.transcriptionFailed),
                context: runtimeContext,
                expectedState: failedState(code: .transcriptionFailed),
                expectedEffects: [expectedEffect(.cleanup)]
            ),
            TransitionFixture(
                name: "raw persistence completes raw path",
                state: rawState,
                intent: .rawPersisted,
                context: .raw,
                expectedState: activeState(stage: .delivering, result: persistentRaw),
                expectedEffects: [expectedEffect(.deliver, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "raw persistence completes polish path",
                state: rawState,
                intent: .rawPersisted,
                context: .polishing,
                expectedState: activeState(stage: .polishing, result: persistentRaw),
                expectedEffects: [expectedEffect(.polish, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "raw persistence failure keeps recoverable volatile raw",
                state: rawState,
                intent: .rawPersistenceFailed(.historyWrite),
                context: runtimeContext,
                expectedState: failedState(code: .historyWrite, recoverable: rawResult),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        ])
    }

    func testResultTimestampComesFromRuntimeContextAndPublicFallbackIsEpoch() {
        let contextualDate = Date(timeIntervalSince1970: 123_456)
        let contextualSnapshot = makeSnapshot(startedAt: contextualDate)
        let contextualToken = EffectToken(sessionID: contextualSnapshot.id, generation: 3)
        let contextualState = PipelineState(
            stage: .transcribing,
            sessionID: contextualSnapshot.id,
            token: contextualToken,
            result: nil,
            failure: nil
        )
        let contextual = DictationReducer.reduce(
            state: contextualState,
            intent: .transcriptionSucceeded("raw"),
            context: .runtime(snapshot: contextualSnapshot, startToken: contextualToken)
        )
        XCTAssertEqual(contextual.state.result?.startedAt, contextualDate)

        let fallback = DictationReducer.reduce(
            state: activeState(stage: .transcribing),
            intent: .transcriptionSucceeded("raw"),
            context: .polishing
        )
        XCTAssertEqual(fallback.state.result?.startedAt, Date(timeIntervalSince1970: 0))
    }

    func testPolishingTransitionTable() {
        let persistentRaw = makeResult(
            rawText: "raw",
            finalText: "raw",
            source: .raw,
            persistence: .persistent
        )
        let volatileRaw = replacing(persistentRaw, persistence: .volatile)
        let polishedPersistent = replacing(
            persistentRaw,
            finalText: "polished",
            source: .polished
        )
        let polishedVolatile = replacing(
            volatileRaw,
            finalText: "polished",
            source: .polished
        )
        let invalidFallbackPersistent = replacing(
            persistentRaw,
            source: .rawFallback,
            warning: .polishInvalidResponse
        )
        let invalidFallbackVolatile = replacing(
            volatileRaw,
            source: .rawFallback,
            warning: .polishInvalidResponse
        )

        assertTransitions([
            TransitionFixture(
                name: "polish success persists selected text",
                state: activeState(stage: .polishing, result: persistentRaw),
                intent: .polishSucceeded(" \n polished \t"),
                context: .polishing,
                expectedState: activeState(stage: .polishing, result: polishedPersistent),
                expectedEffects: [expectedEffect(.persistFinal, payload: .text("polished"))]
            ),
            TransitionFixture(
                name: "no-history polish success delivers selected text",
                state: activeState(stage: .polishing, result: volatileRaw),
                intent: .polishSucceeded(" polished "),
                context: .polishingWithoutHistory,
                expectedState: activeState(stage: .delivering, result: polishedVolatile),
                expectedEffects: [expectedEffect(.deliver, payload: .text("polished"))]
            ),
            TransitionFixture(
                name: "empty polish persists raw fallback",
                state: activeState(stage: .polishing, result: persistentRaw),
                intent: .polishSucceeded(" \n "),
                context: .polishing,
                expectedState: activeState(stage: .polishing, result: invalidFallbackPersistent),
                expectedEffects: [expectedEffect(.persistFinal, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "no-history empty polish delivers raw fallback",
                state: activeState(stage: .polishing, result: volatileRaw),
                intent: .polishSucceeded("\t"),
                context: .polishingWithoutHistory,
                expectedState: activeState(stage: .delivering, result: invalidFallbackVolatile),
                expectedEffects: [expectedEffect(.deliver, payload: .text("raw"))]
            ),
            TransitionFixture(
                name: "final persisted delivers once",
                state: activeState(stage: .polishing, result: polishedPersistent),
                intent: .finalPersisted,
                context: .polishing,
                expectedState: activeState(stage: .delivering, result: polishedPersistent),
                expectedEffects: [expectedEffect(.deliver, payload: .text("polished"))]
            ),
            TransitionFixture(
                name: "final persistence failure keeps recoverable selection",
                state: activeState(stage: .polishing, result: polishedPersistent),
                intent: .finalPersistenceFailed(.historyWrite),
                context: .polishing,
                expectedState: failedState(code: .historyWrite, recoverable: polishedPersistent),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        ])
    }

    func testPolishFailureWarningsAreRestrictedToPolishCodes() {
        let raw = makeResult(
            rawText: "raw",
            finalText: "raw",
            source: .raw,
            persistence: .persistent
        )
        let cases: [(input: DiagnosticCode, expected: DiagnosticCode)] = [
            (.polishTransport, .polishTransport),
            (.polishAuthentication, .polishAuthentication),
            (.polishInvalidResponse, .polishInvalidResponse),
            (.audioStart, .polishInvalidResponse)
        ]

        for item in cases {
            let expectedResult = replacing(
                raw,
                source: .rawFallback,
                warning: item.expected
            )
            assertTransition(
                name: "sanitize \(item.input.rawValue)",
                state: activeState(stage: .polishing, result: raw),
                intent: .polishFailed(item.input),
                context: .polishing,
                expectedState: activeState(stage: .polishing, result: expectedResult),
                expectedEffects: [expectedEffect(.persistFinal, payload: .text("raw"))]
            )
        }

        let volatileRaw = replacing(raw, persistence: .volatile)
        let volatileFallback = replacing(
            volatileRaw,
            source: .rawFallback,
            warning: .polishTransport
        )
        assertTransition(
            name: "no-history polish failure delivers fallback",
            state: activeState(stage: .polishing, result: volatileRaw),
            intent: .polishFailed(.polishTransport),
            context: .polishingWithoutHistory,
            expectedState: activeState(stage: .delivering, result: volatileFallback),
            expectedEffects: [expectedEffect(.deliver, payload: .text("raw"))]
        )
    }

    func testDeliveryTransitionTableCoversEveryOutcomeAndHistoryBranch() {
        let outcomes: [DeliveryOutcome] = [
            .pasteEventDispatched,
            .deliveredToOnboardingTest,
            .copiedByPreference,
            .copiedByUser,
            .manualCopyRequired(.deliveryTargetChanged)
        ]
        let persistent = makeResult(
            rawText: "raw",
            finalText: "final",
            source: .polished,
            persistence: .persistent
        )
        let volatile = replacing(persistent, persistence: .volatile)

        for outcome in outcomes {
            let persistentDelivered = replacing(persistent, delivery: outcome)
            assertTransition(
                name: "history delivery outcome \(outcome)",
                state: activeState(stage: .delivering, result: persistent),
                intent: .deliveryFinished(outcome),
                context: .polishing,
                expectedState: activeState(stage: .delivering, result: persistentDelivered),
                expectedEffects: [expectedEffect(.persistDelivery)]
            )

            let volatileDelivered = replacing(volatile, delivery: outcome)
            assertTransition(
                name: "no-history delivery outcome \(outcome)",
                state: activeState(stage: .delivering, result: volatile),
                intent: .deliveryFinished(outcome),
                context: .polishingWithoutHistory,
                expectedState: activeState(stage: .completed, result: volatileDelivered),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        }

        let delivered = replacing(persistent, delivery: .copiedByPreference)
        assertTransitions([
            TransitionFixture(
                name: "delivery persisted",
                state: activeState(stage: .delivering, result: delivered),
                intent: .deliveryPersisted,
                context: .polishing,
                expectedState: activeState(stage: .completed, result: delivered),
                expectedEffects: [expectedEffect(.cleanup)]
            ),
            TransitionFixture(
                name: "delivery persistence failure completes without redelivery",
                state: activeState(stage: .delivering, result: delivered),
                intent: .deliveryPersistenceFailed(.historyWrite),
                context: .polishing,
                expectedState: activeState(
                    stage: .completed,
                    result: replacing(delivered, warning: .historyWrite)
                ),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        ])

        let unlistedCodeState = activeState(stage: .delivering, result: delivered)
        let unlistedCode = DictationReducer.reduce(
            state: unlistedCodeState,
            intent: .deliveryPersistenceFailed(.audioStart),
            context: .polishing
        )
        XCTAssertEqual(unlistedCode.state, unlistedCodeState)
        XCTAssertTrue(unlistedCode.effects.isEmpty)
    }

    func testCancellationAndAcknowledgementTerminalShapes() {
        let activeStages: [PipelineStage] = [
            .requestingPermission, .recording, .stopping, .transcribing, .polishing, .delivering
        ]
        for stage in activeStages {
            let original = activeState(stage: stage)
            assertTransition(
                name: "cancel before raw from \(stage.rawValue)",
                state: original,
                intent: .cancel,
                context: .polishing,
                expectedState: .idle,
                expectedEffects: [expectedEffect(.cleanup)]
            )
        }

        let raw = makeResult(rawText: "raw", finalText: "raw", source: .raw)
        let polished = makeResult(
            rawText: "raw",
            finalText: "polished",
            source: .polished,
            delivery: .copiedByPreference,
            persistence: .persistent
        )
        let fallback = makeResult(
            rawText: "raw",
            finalText: "raw",
            source: .rawFallback,
            warning: .polishTransport,
            delivery: .manualCopyRequired(.deliveryTargetUnavailable),
            persistence: .persistent
        )
        let afterRaw: [(PipelineStage, DictationResult)] = [
            (.transcribing, raw),
            (.polishing, polished),
            (.delivering, fallback)
        ]
        for (stage, result) in afterRaw {
            let cancelled = replacing(result, warning: .cancelled)
            assertTransition(
                name: "cancel after raw from \(stage.rawValue)",
                state: activeState(stage: stage, result: result),
                intent: .cancel,
                context: .polishing,
                expectedState: activeState(stage: .completed, result: cancelled),
                expectedEffects: [expectedEffect(.cleanup)]
            )
        }

        let completed = activeState(stage: .completed, result: polished)
        let failed = failedState(code: .historyWrite, recoverable: polished)
        assertTransitions([
            TransitionFixture(
                name: "acknowledge completed",
                state: completed,
                intent: .acknowledge,
                context: .polishing,
                expectedState: .idle,
                expectedEffects: []
            ),
            TransitionFixture(
                name: "acknowledge failed",
                state: failed,
                intent: .acknowledge,
                context: .polishing,
                expectedState: .idle,
                expectedEffects: []
            )
        ])
    }

    func testEveryUnlistedStageIntentPairIsAnExactNoOp() {
        let stages: [PipelineStage] = [
            .idle, .requestingPermission, .recording, .stopping, .transcribing,
            .polishing, .delivering, .completed, .failed
        ]
        let intents = representativeIntents()

        for stage in stages {
            for fixture in intents where !isListed(stage: stage, intent: fixture.kind) {
                let original = representativeState(for: stage)
                let reduction = DictationReducer.reduce(
                    state: original,
                    intent: fixture.intent,
                    context: .polishing
                )
                XCTAssertEqual(
                    reduction.state,
                    original,
                    "Unexpected mutation for \(stage.rawValue) x \(fixture.kind)"
                )
                XCTAssertTrue(
                    reduction.effects.isEmpty,
                    "Unexpected effect for \(stage.rawValue) x \(fixture.kind)"
                )
            }
        }
    }

    func testEveryListedNonStartTransitionRejectsMissingOrMismatchedIdentity() {
        let stages: [PipelineStage] = [
            .requestingPermission, .recording, .stopping, .transcribing,
            .polishing, .delivering, .completed, .failed
        ]
        let intents = representativeIntents()

        for stage in stages {
            for fixture in intents where fixture.kind != .start && isListed(stage: stage, intent: fixture.kind) {
                let valid = representativeState(for: stage)
                let malformedStates = [
                    PipelineState(
                        stage: valid.stage,
                        sessionID: nil,
                        token: valid.token,
                        result: valid.result,
                        failure: valid.failure
                    ),
                    PipelineState(
                        stage: valid.stage,
                        sessionID: valid.sessionID,
                        token: nil,
                        result: valid.result,
                        failure: valid.failure
                    ),
                    PipelineState(
                        stage: valid.stage,
                        sessionID: valid.sessionID,
                        token: EffectToken(sessionID: SessionID(), generation: token.generation),
                        result: valid.result,
                        failure: valid.failure
                    )
                ]

                for malformed in malformedStates {
                    let reduction = DictationReducer.reduce(
                        state: malformed,
                        intent: fixture.intent,
                        context: .polishing
                    )
                    XCTAssertEqual(
                        reduction.state,
                        malformed,
                        "Malformed identity mutated for \(stage.rawValue) x \(fixture.kind)"
                    )
                    XCTAssertTrue(
                        reduction.effects.isEmpty,
                        "Malformed identity emitted for \(stage.rawValue) x \(fixture.kind)"
                    )
                }
            }
        }
    }

    func testDeterministicAppClockAdvancesWithoutWallClockSleep() async throws {
        let clock = TestAppClock(now: Date(timeIntervalSince1970: 10))
        let sleep = Task {
            try await clock.sleep(for: .seconds(5))
        }
        await waitUntil { clock.pendingSleepCount == 1 }

        clock.advance(by: .seconds(4))
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 14))
        XCTAssertEqual(clock.pendingSleepCount, 1)

        clock.advance(by: .seconds(1))
        try await sleep.value
        XCTAssertEqual(clock.now, Date(timeIntervalSince1970: 15))
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    func testDeterministicAppClockObservesCancellation() async {
        let clock = TestAppClock(now: Date(timeIntervalSince1970: 20))
        let sleep = Task {
            try await clock.sleep(for: .seconds(5))
        }
        await waitUntil { clock.pendingSleepCount == 1 }

        sleep.cancel()
        do {
            try await sleep.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertEqual(clock.cancellationCount, 1)
        XCTAssertEqual(clock.pendingSleepCount, 0)
    }

    private var token: EffectToken {
        EffectToken(sessionID: snapshot.id, generation: 42)
    }

    private var audioURL: URL {
        URL(fileURLWithPath: "/private/tmp/utterink-task3-audio.wav")
    }

    private func makeSnapshot(
        id: SessionID? = nil,
        startedAt: Date? = nil,
        skipsPolishing: Bool = false,
        historyGeneration: UInt64 = 1,
        historyEnabled: Bool = true
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: id ?? snapshot.id,
            startedAt: startedAt ?? snapshot.startedAt,
            target: .copyOnly,
            recognition: .fixed(languageCode: "en"),
            speechModelID: "small",
            outputMode: OutputMode(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                title: skipsPolishing ? "Raw" : "Polish",
                skipsPolishing: skipsPolishing,
                instructions: skipsPolishing ? "" : "clean"
            ),
            provider: nil,
            historyGeneration: historyGeneration,
            historyEnabled: historyEnabled,
            deliveryPreference: .copyOnly,
            credential: nil
        )
    }

    private func makeResult(
        rawText: String,
        finalText: String,
        source: ResultSource,
        warning: DiagnosticCode? = nil,
        delivery: DeliveryOutcome? = nil,
        persistence: ResultPersistence = .volatile
    ) -> DictationResult {
        DictationResult(
            sessionID: snapshot.id,
            startedAt: snapshot.startedAt,
            rawText: rawText,
            finalText: finalText,
            source: source,
            warning: warning,
            delivery: delivery,
            persistence: persistence
        )
    }

    private func replacing(
        _ result: DictationResult,
        finalText: String? = nil,
        source: ResultSource? = nil,
        warning: DiagnosticCode?? = nil,
        delivery: DeliveryOutcome?? = nil,
        persistence: ResultPersistence? = nil
    ) -> DictationResult {
        DictationResult(
            sessionID: result.sessionID,
            startedAt: result.startedAt,
            rawText: result.rawText,
            finalText: finalText ?? result.finalText,
            source: source ?? result.source,
            warning: warning ?? result.warning,
            delivery: delivery ?? result.delivery,
            persistence: persistence ?? result.persistence
        )
    }

    private func activeState(
        stage: PipelineStage,
        result: DictationResult? = nil,
        failure: PipelineFailure? = nil
    ) -> PipelineState {
        PipelineState(
            stage: stage,
            sessionID: snapshot.id,
            token: token,
            result: result,
            failure: failure
        )
    }

    private func failedState(
        code: DiagnosticCode,
        recoverable: DictationResult? = nil
    ) -> PipelineState {
        PipelineState(
            stage: .failed,
            sessionID: snapshot.id,
            token: token,
            result: recoverable,
            failure: PipelineFailure(code: code, recoverableResult: recoverable)
        )
    }

    private func expectedEffect(
        _ kind: DictationEffectKind,
        payload: ExpectedPayload = .none
    ) -> ExpectedEffect {
        ExpectedEffect(kind: kind, token: token, payload: payload)
    }

    private func assertTransitions(
        _ fixtures: [TransitionFixture],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fixture in fixtures {
            assertTransition(
                name: fixture.name,
                state: fixture.state,
                intent: fixture.intent,
                context: fixture.context,
                expectedState: fixture.expectedState,
                expectedEffects: fixture.expectedEffects,
                file: file,
                line: line
            )
        }
    }

    private func assertTransition(
        name: String,
        state: PipelineState,
        intent: DictationIntent,
        context: ReducerContext,
        expectedState: PipelineState,
        expectedEffects: [ExpectedEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reduction = DictationReducer.reduce(state: state, intent: intent, context: context)
        XCTAssertEqual(reduction.state, expectedState, name, file: file, line: line)
        assertEffects(
            reduction.effects,
            equal: expectedEffects,
            name: name,
            file: file,
            line: line
        )
    }

    private func assertEffects(
        _ actual: [DictationEffect],
        equal expected: [ExpectedEffect],
        name: String,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(actual.count, expected.count, name, file: file, line: line)
        guard actual.count == expected.count else { return }

        for (actualEffect, expectedEffect) in zip(actual, expected) {
            XCTAssertEqual(actualEffect.kind, expectedEffect.kind, name, file: file, line: line)
            XCTAssertEqual(actualEffect.token, expectedEffect.token, name, file: file, line: line)
            switch actualEffect.payload {
            case .none:
                guard case .none = expectedEffect.payload else {
                    XCTFail("\(name): expected non-none payload", file: file, line: line)
                    continue
                }
            case let .recording(handle):
                guard case let .recording(expectedHandle) = expectedEffect.payload else {
                    XCTFail("\(name): unexpected recording payload", file: file, line: line)
                    continue
                }
                XCTAssertEqual(handle, expectedHandle, name, file: file, line: line)
            case let .audio(url):
                guard case let .audio(expectedURL) = expectedEffect.payload else {
                    XCTFail("\(name): unexpected audio payload", file: file, line: line)
                    continue
                }
                XCTAssertEqual(url, expectedURL, name, file: file, line: line)
            case let .text(text):
                guard case let .text(expectedText) = expectedEffect.payload else {
                    XCTFail("\(name): unexpected text payload", file: file, line: line)
                    continue
                }
                XCTAssertEqual(text, expectedText, name, file: file, line: line)
            }
        }
    }

    private func representativeIntents() -> [IntentFixture] {
        [
            IntentFixture(kind: .start, intent: .start(snapshot)),
            IntentFixture(kind: .microphoneResolved, intent: .microphoneResolved(.granted)),
            IntentFixture(
                kind: .recordingStarted,
                intent: .recordingStarted(
                    RecordingHandle(
                        rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
                    )
                )
            ),
            IntentFixture(kind: .recordingStartFailed, intent: .recordingStartFailed(.audioStart)),
            IntentFixture(kind: .stopRequested, intent: .stopRequested),
            IntentFixture(kind: .audioFinalized, intent: .audioFinalized(audioURL)),
            IntentFixture(
                kind: .audioFinalizationFailed,
                intent: .audioFinalizationFailed(.audioFinalize)
            ),
            IntentFixture(
                kind: .transcriptionSucceeded,
                intent: .transcriptionSucceeded("raw")
            ),
            IntentFixture(
                kind: .transcriptionFailed,
                intent: .transcriptionFailed(.transcriptionFailed)
            ),
            IntentFixture(kind: .rawPersisted, intent: .rawPersisted),
            IntentFixture(
                kind: .rawPersistenceFailed,
                intent: .rawPersistenceFailed(.historyWrite)
            ),
            IntentFixture(kind: .polishSucceeded, intent: .polishSucceeded("polished")),
            IntentFixture(kind: .polishFailed, intent: .polishFailed(.polishTransport)),
            IntentFixture(kind: .finalPersisted, intent: .finalPersisted),
            IntentFixture(
                kind: .finalPersistenceFailed,
                intent: .finalPersistenceFailed(.historyWrite)
            ),
            IntentFixture(
                kind: .deliveryFinished,
                intent: .deliveryFinished(.copiedByPreference)
            ),
            IntentFixture(kind: .deliveryPersisted, intent: .deliveryPersisted),
            IntentFixture(
                kind: .deliveryPersistenceFailed,
                intent: .deliveryPersistenceFailed(.historyWrite)
            ),
            IntentFixture(kind: .cancel, intent: .cancel),
            IntentFixture(kind: .acknowledge, intent: .acknowledge)
        ]
    }

    private func representativeState(for stage: PipelineStage) -> PipelineState {
        let raw = makeResult(
            rawText: "raw",
            finalText: "raw",
            source: .raw,
            persistence: .persistent
        )
        switch stage {
        case .idle:
            return .idle
        case .requestingPermission, .recording, .stopping:
            return activeState(stage: stage)
        case .transcribing, .polishing, .delivering, .completed:
            return activeState(stage: stage, result: raw)
        case .failed:
            return failedState(code: .historyWrite, recoverable: raw)
        }
    }

    private func isListed(stage: PipelineStage, intent: IntentKind) -> Bool {
        switch (stage, intent) {
        case (.idle, .start), (.completed, .start), (.failed, .start):
            return true
        case (.requestingPermission, .microphoneResolved),
             (.requestingPermission, .recordingStarted),
             (.requestingPermission, .recordingStartFailed):
            return true
        case (.recording, .stopRequested):
            return true
        case (.stopping, .audioFinalized),
             (.stopping, .audioFinalizationFailed):
            return true
        case (.transcribing, .transcriptionSucceeded),
             (.transcribing, .transcriptionFailed),
             (.transcribing, .rawPersisted),
             (.transcribing, .rawPersistenceFailed):
            return true
        case (.polishing, .polishSucceeded),
             (.polishing, .polishFailed),
             (.polishing, .finalPersisted),
             (.polishing, .finalPersistenceFailed):
            return true
        case (.delivering, .deliveryFinished),
             (.delivering, .deliveryPersisted),
             (.delivering, .deliveryPersistenceFailed):
            return true
        case (.requestingPermission, .cancel),
             (.recording, .cancel),
             (.stopping, .cancel),
             (.transcribing, .cancel),
             (.polishing, .cancel),
             (.delivering, .cancel):
            return true
        case (.completed, .acknowledge), (.failed, .acknowledge):
            return true
        default:
            return false
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic test condition")
    }

    private struct TransitionFixture {
        let name: String
        let state: PipelineState
        let intent: DictationIntent
        let context: ReducerContext
        let expectedState: PipelineState
        let expectedEffects: [ExpectedEffect]
    }

    private struct ExpectedEffect {
        let kind: DictationEffectKind
        let token: EffectToken
        let payload: ExpectedPayload
    }

    private enum ExpectedPayload {
        case none
        case recording(RecordingHandle)
        case audio(URL)
        case text(String)
    }

    private struct IntentFixture {
        let kind: IntentKind
        let intent: DictationIntent
    }

    private enum IntentKind: Equatable {
        case start
        case microphoneResolved
        case recordingStarted
        case recordingStartFailed
        case stopRequested
        case audioFinalized
        case audioFinalizationFailed
        case transcriptionSucceeded
        case transcriptionFailed
        case rawPersisted
        case rawPersistenceFailed
        case polishSucceeded
        case polishFailed
        case finalPersisted
        case finalPersistenceFailed
        case deliveryFinished
        case deliveryPersisted
        case deliveryPersistenceFailed
        case cancel
        case acknowledge
    }
}

private final class TestAppClock: AppClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancellations = 0

    init(now: Date) {
        current = now
    }

    var now: Date {
        lock.withLock { current }
    }

    var pendingSleepCount: Int {
        lock.withLock { sleepers.count }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = lock.withLock {
            current.addingTimeInterval(Self.timeInterval(for: duration))
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                var immediateResult: Result<Void, Error>?
                lock.lock()
                if Task.isCancelled {
                    cancellations += 1
                    immediateResult = .failure(CancellationError())
                } else if current >= deadline {
                    immediateResult = .success(())
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                }
                lock.unlock()

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            self.cancelSleep(id: id)
        }
    }

    func advance(by duration: Duration) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            current = current.addingTimeInterval(Self.timeInterval(for: duration))
            let readyIDs = sleepers.compactMap { id, sleeper in
                sleeper.deadline <= current ? id : nil
            }
            return readyIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
        }
        ready.forEach { $0.resume() }
    }

    private func cancelSleep(id: UUID) {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard let sleeper = sleepers.removeValue(forKey: id) else { return nil }
            cancellations += 1
            return sleeper.continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
