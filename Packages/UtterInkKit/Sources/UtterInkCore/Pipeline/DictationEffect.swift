import Foundation

public enum DictationEffectKind: Equatable, Sendable {
    case requestMicrophone
    case startRecording
    case stopRecording
    case transcribe
    case persistRaw
    case polish
    case persistFinal
    case deliver
    case persistDelivery
    case cleanup
}

public struct DictationEffect: Sendable {
    public let kind: DictationEffectKind
    public let token: EffectToken
    public let payload: Payload

    public enum Payload: Sendable {
        case none
        case recording(RecordingHandle)
        case audio(URL)
        case text(String)
    }

    public init(kind: DictationEffectKind, token: EffectToken, payload: Payload) {
        self.kind = kind
        self.token = token
        self.payload = payload
    }
}

public struct ReducerContext: Equatable, Sendable {
    public let skipsPolishing: Bool
    public let historyEnabled: Bool

    let startToken: EffectToken?
    let sessionStartedAt: Date

    public init(skipsPolishing: Bool, historyEnabled: Bool) {
        self.skipsPolishing = skipsPolishing
        self.historyEnabled = historyEnabled
        startToken = nil
        sessionStartedAt = Date(timeIntervalSince1970: 0)
    }

    public static let raw = ReducerContext(skipsPolishing: true, historyEnabled: true)
    public static let polishing = ReducerContext(skipsPolishing: false, historyEnabled: true)
    public static let polishingWithoutHistory = ReducerContext(
        skipsPolishing: false,
        historyEnabled: false
    )

    static func runtime(snapshot: SessionSnapshot, startToken: EffectToken) -> ReducerContext {
        ReducerContext(
            skipsPolishing: snapshot.outputMode.skipsPolishing,
            historyEnabled: snapshot.historyEnabled,
            startToken: startToken,
            sessionStartedAt: snapshot.startedAt
        )
    }

    private init(
        skipsPolishing: Bool,
        historyEnabled: Bool,
        startToken: EffectToken?,
        sessionStartedAt: Date
    ) {
        self.skipsPolishing = skipsPolishing
        self.historyEnabled = historyEnabled
        self.startToken = startToken
        self.sessionStartedAt = sessionStartedAt
    }
}

public struct Reduction: Sendable {
    public let state: PipelineState
    public let effects: [DictationEffect]

    public init(state: PipelineState, effects: [DictationEffect]) {
        self.state = state
        self.effects = effects
    }
}
