import Foundation

public enum PipelineStage: String, Codable, Sendable {
    case idle, requestingPermission, recording, stopping, transcribing, polishing, delivering, completed, failed
}

public struct PipelineFailure: Equatable, Sendable {
    public let code: DiagnosticCode
    public let recoverableResult: DictationResult?

    public init(code: DiagnosticCode, recoverableResult: DictationResult?) {
        self.code = code
        self.recoverableResult = recoverableResult
    }
}

public struct PipelineState: Equatable, Sendable {
    public var stage: PipelineStage
    public var sessionID: SessionID?
    public var token: EffectToken?
    public var result: DictationResult?
    public var failure: PipelineFailure?

    public init(
        stage: PipelineStage,
        sessionID: SessionID?,
        token: EffectToken?,
        result: DictationResult?,
        failure: PipelineFailure?
    ) {
        self.stage = stage
        self.sessionID = sessionID
        self.token = token
        self.result = result
        self.failure = failure
    }

    public static let idle = PipelineState(
        stage: .idle,
        sessionID: nil,
        token: nil,
        result: nil,
        failure: nil
    )
}
