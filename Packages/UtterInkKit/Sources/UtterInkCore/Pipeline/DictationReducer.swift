import Foundation

public enum DictationReducer {
    public static func reduce(
        state: PipelineState,
        intent: DictationIntent,
        context: ReducerContext
    ) -> Reduction {
        if case let .start(snapshot) = intent {
            return reduceStart(state: state, snapshot: snapshot, context: context)
        }

        guard
            let sessionID = state.sessionID,
            let token = state.token,
            token.sessionID == sessionID
        else {
            return noOp(state)
        }

        if case .cancel = intent {
            return reduceCancel(state: state, token: token)
        }

        switch (state.stage, intent) {
        case (.requestingPermission, .microphoneResolved(.granted)):
            return Reduction(
                state: activeState(stage: .requestingPermission, sessionID: sessionID, token: token),
                effects: [effect(.startRecording, token: token)]
            )

        case (.requestingPermission, .microphoneResolved(.denied)),
             (.requestingPermission, .microphoneResolved(.notDetermined)):
            return fail(code: .permissionMicrophone, sessionID: sessionID, token: token)

        case (.requestingPermission, .recordingStarted):
            return Reduction(
                state: activeState(stage: .recording, sessionID: sessionID, token: token),
                effects: []
            )

        case let (.requestingPermission, .recordingStartFailed(code)):
            return fail(code: code, sessionID: sessionID, token: token)

        case (.recording, .stopRequested):
            return Reduction(
                state: activeState(stage: .stopping, sessionID: sessionID, token: token),
                effects: [effect(.stopRecording, token: token)]
            )

        case let (.stopping, .audioFinalized(url)):
            return Reduction(
                state: activeState(stage: .transcribing, sessionID: sessionID, token: token),
                effects: [effect(.transcribe, token: token, payload: .audio(url))]
            )

        case let (.stopping, .audioFinalizationFailed(code)):
            return fail(code: code, sessionID: sessionID, token: token)

        case let (.transcribing, .transcriptionSucceeded(text)):
            return reduceTranscription(
                text: text,
                sessionID: sessionID,
                token: token,
                context: context
            )

        case let (.transcribing, .transcriptionFailed(code)):
            return fail(code: code, sessionID: sessionID, token: token)

        case (.transcribing, .rawPersisted):
            guard let result = state.result else { return noOp(state) }
            let persistent = rebuild(result, persistence: .persistent)
            if context.skipsPolishing {
                return Reduction(
                    state: activeState(
                        stage: .delivering,
                        sessionID: sessionID,
                        token: token,
                        result: persistent
                    ),
                    effects: [effect(.deliver, token: token, payload: .text(persistent.finalText))]
                )
            }
            return Reduction(
                state: activeState(
                    stage: .polishing,
                    sessionID: sessionID,
                    token: token,
                    result: persistent
                ),
                effects: [effect(.polish, token: token, payload: .text(persistent.rawText))]
            )

        case let (.transcribing, .rawPersistenceFailed(code)):
            guard let result = state.result else { return noOp(state) }
            return fail(code: code, recoverable: result, sessionID: sessionID, token: token)

        case let (.polishing, .polishSucceeded(text)):
            guard let result = state.result else { return noOp(state) }
            let trimmed = trim(text)
            let selected: DictationResult
            if trimmed.isEmpty {
                selected = rebuild(
                    result,
                    finalText: result.rawText,
                    source: .rawFallback,
                    warning: .polishInvalidResponse
                )
            } else {
                selected = rebuild(
                    result,
                    finalText: trimmed,
                    source: .polished,
                    warning: nil
                )
            }
            return advanceSelectedResult(selected, token: token, context: context)

        case let (.polishing, .polishFailed(code)):
            guard let result = state.result else { return noOp(state) }
            let fallback = rebuild(
                result,
                finalText: result.rawText,
                source: .rawFallback,
                warning: sanitizedPolishCode(code)
            )
            return advanceSelectedResult(fallback, token: token, context: context)

        case (.polishing, .finalPersisted):
            guard let result = state.result else { return noOp(state) }
            return Reduction(
                state: activeState(
                    stage: .delivering,
                    sessionID: sessionID,
                    token: token,
                    result: result
                ),
                effects: [effect(.deliver, token: token, payload: .text(result.finalText))]
            )

        case let (.polishing, .finalPersistenceFailed(code)):
            guard let result = state.result else { return noOp(state) }
            return fail(code: code, recoverable: result, sessionID: sessionID, token: token)

        case let (.delivering, .deliveryFinished(outcome)):
            guard let result = state.result else { return noOp(state) }
            let delivered = rebuild(result, delivery: outcome)
            if context.historyEnabled {
                return Reduction(
                    state: activeState(
                        stage: .delivering,
                        sessionID: sessionID,
                        token: token,
                        result: delivered
                    ),
                    effects: [effect(.persistDelivery, token: token)]
                )
            }
            return Reduction(
                state: activeState(
                    stage: .completed,
                    sessionID: sessionID,
                    token: token,
                    result: delivered
                ),
                effects: [effect(.cleanup, token: token)]
            )

        case (.delivering, .deliveryPersisted):
            guard let result = state.result else { return noOp(state) }
            return Reduction(
                state: activeState(
                    stage: .completed,
                    sessionID: sessionID,
                    token: token,
                    result: result
                ),
                effects: [effect(.cleanup, token: token)]
            )

        case (.delivering, .deliveryPersistenceFailed(.historyWrite)):
            guard let result = state.result else { return noOp(state) }
            let warned = rebuild(result, warning: .historyWrite)
            return Reduction(
                state: activeState(
                    stage: .completed,
                    sessionID: sessionID,
                    token: token,
                    result: warned
                ),
                effects: [effect(.cleanup, token: token)]
            )

        case (.completed, .acknowledge), (.failed, .acknowledge):
            return Reduction(state: .idle, effects: [])

        default:
            return noOp(state)
        }
    }

    private static func reduceStart(
        state: PipelineState,
        snapshot: SessionSnapshot,
        context: ReducerContext
    ) -> Reduction {
        switch state.stage {
        case .idle, .completed, .failed:
            let token: EffectToken
            if let contextualToken = context.startToken,
               contextualToken.sessionID == snapshot.id {
                token = contextualToken
            } else if let stateToken = state.token,
                      stateToken.sessionID == snapshot.id {
                token = stateToken
            } else {
                token = EffectToken(sessionID: snapshot.id, generation: 0)
            }
            return Reduction(
                state: activeState(
                    stage: .requestingPermission,
                    sessionID: snapshot.id,
                    token: token
                ),
                effects: [effect(.requestMicrophone, token: token)]
            )
        default:
            return noOp(state)
        }
    }

    private static func reduceTranscription(
        text: String,
        sessionID: SessionID,
        token: EffectToken,
        context: ReducerContext
    ) -> Reduction {
        let trimmed = trim(text)
        guard !trimmed.isEmpty else {
            return fail(code: .transcriptionEmpty, sessionID: sessionID, token: token)
        }

        let result = DictationResult(
            sessionID: sessionID,
            startedAt: context.sessionStartedAt,
            rawText: trimmed,
            finalText: trimmed,
            source: .raw,
            warning: nil,
            delivery: nil,
            persistence: .volatile
        )

        if context.historyEnabled {
            return Reduction(
                state: activeState(
                    stage: .transcribing,
                    sessionID: sessionID,
                    token: token,
                    result: result
                ),
                effects: [effect(.persistRaw, token: token, payload: .text(trimmed))]
            )
        }

        if context.skipsPolishing {
            return Reduction(
                state: activeState(
                    stage: .delivering,
                    sessionID: sessionID,
                    token: token,
                    result: result
                ),
                effects: [effect(.deliver, token: token, payload: .text(trimmed))]
            )
        }

        return Reduction(
            state: activeState(
                stage: .polishing,
                sessionID: sessionID,
                token: token,
                result: result
            ),
            effects: [effect(.polish, token: token, payload: .text(trimmed))]
        )
    }

    private static func advanceSelectedResult(
        _ result: DictationResult,
        token: EffectToken,
        context: ReducerContext
    ) -> Reduction {
        if context.historyEnabled {
            return Reduction(
                state: activeState(
                    stage: .polishing,
                    sessionID: token.sessionID,
                    token: token,
                    result: result
                ),
                effects: [effect(.persistFinal, token: token, payload: .text(result.finalText))]
            )
        }
        return Reduction(
            state: activeState(
                stage: .delivering,
                sessionID: token.sessionID,
                token: token,
                result: result
            ),
            effects: [effect(.deliver, token: token, payload: .text(result.finalText))]
        )
    }

    private static func reduceCancel(state: PipelineState, token: EffectToken) -> Reduction {
        switch state.stage {
        case .requestingPermission, .recording, .stopping, .transcribing, .polishing, .delivering:
            if isAfterRawStage(state.stage),
               let result = state.result,
               !trim(result.rawText).isEmpty {
                let cancelled = rebuild(result, warning: .cancelled)
                return Reduction(
                    state: activeState(
                        stage: .completed,
                        sessionID: token.sessionID,
                        token: token,
                        result: cancelled
                    ),
                    effects: [effect(.cleanup, token: token)]
                )
            }
            return Reduction(
                state: .idle,
                effects: [effect(.cleanup, token: token)]
            )
        default:
            return noOp(state)
        }
    }

    private static func isAfterRawStage(_ stage: PipelineStage) -> Bool {
        switch stage {
        case .transcribing, .polishing, .delivering:
            return true
        default:
            return false
        }
    }

    private static func activeState(
        stage: PipelineStage,
        sessionID: SessionID,
        token: EffectToken,
        result: DictationResult? = nil
    ) -> PipelineState {
        PipelineState(
            stage: stage,
            sessionID: sessionID,
            token: token,
            result: result,
            failure: nil
        )
    }

    private static func fail(
        code: DiagnosticCode,
        recoverable: DictationResult? = nil,
        sessionID: SessionID,
        token: EffectToken
    ) -> Reduction {
        let failure = PipelineFailure(code: code, recoverableResult: recoverable)
        return Reduction(
            state: PipelineState(
                stage: .failed,
                sessionID: sessionID,
                token: token,
                result: recoverable,
                failure: failure
            ),
            effects: [effect(.cleanup, token: token)]
        )
    }

    private static func effect(
        _ kind: DictationEffectKind,
        token: EffectToken,
        payload: DictationEffect.Payload = .none
    ) -> DictationEffect {
        DictationEffect(kind: kind, token: token, payload: payload)
    }

    private static func rebuild(
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

    private static func sanitizedPolishCode(_ code: DiagnosticCode) -> DiagnosticCode {
        switch code {
        case .polishTransport, .polishAuthentication, .polishInvalidResponse:
            return code
        default:
            return .polishInvalidResponse
        }
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func noOp(_ state: PipelineState) -> Reduction {
        Reduction(state: state, effects: [])
    }
}
