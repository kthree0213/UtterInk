import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class WhisperTranscriberTests: XCTestCase {
    func testPublicConstructionConformsToTranscriptionService() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let models = try WhisperModelService(
            catalog: .bundled,
            root: root,
            clock: TranscriberTestClock()
        )

        let transcriber: any TranscriptionService = WhisperTranscriber(models: models)

        XCTAssertNotNil(transcriber)
    }

    func testAutomaticAndFixedConfigurationsMapExactlyAndSegmentsJoinTrimmed() async throws {
        let runtime = TranscriptionRuntimeFake(outcome: .success(["  hello ", " world  "]))
        let ready = try await makeReadyTranscriber(runtime: runtime)
        let audioURL = URL(fileURLWithPath: "/private/tmp/utterink-audio.caf")

        let automatic = try await ready.transcriber.transcribe(
            audioURL: audioURL,
            model: ready.lease,
            configuration: .automatic,
            token: ready.token
        )
        let fixed = try await ready.transcriber.transcribe(
            audioURL: audioURL,
            model: ready.lease,
            configuration: .fixed(languageCode: "zh"),
            token: ready.token
        )

        XCTAssertEqual(automatic, "hello world")
        XCTAssertEqual(fixed, "hello world")
        let calls = await runtime.recordedCalls()
        XCTAssertEqual(calls, [
            RuntimeCall(audioURL: audioURL, options: .init(language: nil, detectLanguage: true)),
            RuntimeCall(audioURL: audioURL, options: .init(language: "zh", detectLanguage: false))
        ])
    }

    func testWhitespaceOnlyResultThrowsTranscriptionEmpty() async throws {
        let runtime = TranscriptionRuntimeFake(outcome: .success([" ", "\n\t"]))
        let ready = try await makeReadyTranscriber(runtime: runtime)

        let code = await diagnostic {
            try await ready.transcriber.transcribe(
                audioURL: URL(fileURLWithPath: "/private/tmp/empty.caf"),
                model: ready.lease,
                configuration: .automatic,
                token: ready.token
            )
        }

        XCTAssertEqual(code, .transcriptionEmpty)
    }

    func testBackendFailureAndCancellationMapToClosedDiagnostics() async throws {
        for (outcome, expected) in [
            (TranscriptionOutcome.failure, DiagnosticCode.transcriptionFailed),
            (.cancelled, .cancelled)
        ] {
            let runtime = TranscriptionRuntimeFake(outcome: outcome)
            let ready = try await makeReadyTranscriber(runtime: runtime)
            let code = await diagnostic {
                try await ready.transcriber.transcribe(
                    audioURL: URL(fileURLWithPath: "/private/tmp/failure.caf"),
                    model: ready.lease,
                    configuration: .automatic,
                    token: ready.token
                )
            }
            XCTAssertEqual(code, expected)
        }
    }

    func testInvalidLeaseModelOrFullTokenNeverInvokesRuntime() async throws {
        let runtime = TranscriptionRuntimeFake(outcome: .success(["must-not-run"]))
        let ready = try await makeReadyTranscriber(runtime: runtime)
        let wrongToken = EffectToken(
            sessionID: SessionID(),
            generation: ready.token.generation
        )
        let invalidLease = SpeechModelLease(
            modelID: "small",
            generation: ready.token.generation
        )

        let wrongTokenCode = await diagnostic {
            try await ready.transcriber.transcribe(
                audioURL: URL(fileURLWithPath: "/private/tmp/invalid.caf"),
                model: ready.lease,
                configuration: .automatic,
                token: wrongToken
            )
        }
        let invalidLeaseCode = await diagnostic {
            try await ready.transcriber.transcribe(
                audioURL: URL(fileURLWithPath: "/private/tmp/invalid.caf"),
                model: invalidLease,
                configuration: .automatic,
                token: ready.token
            )
        }
        await ready.models.release(ready.lease)
        let releasedCode = await diagnostic {
            try await ready.transcriber.transcribe(
                audioURL: URL(fileURLWithPath: "/private/tmp/invalid.caf"),
                model: ready.lease,
                configuration: .automatic,
                token: ready.token
            )
        }

        XCTAssertEqual(wrongTokenCode, .transcriptionFailed)
        XCTAssertEqual(invalidLeaseCode, .transcriptionFailed)
        XCTAssertEqual(releasedCode, .transcriptionFailed)
        let callCount = await runtime.callCount()
        XCTAssertEqual(callCount, 0)
    }
}

private struct TranscriberTestClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func sleep(for duration: Duration) async throws {}
}

private enum TranscriptionOutcome: Sendable {
    case success([String])
    case failure
    case cancelled
}

private struct RuntimeCall: Equatable, Sendable {
    let audioURL: URL
    let options: WhisperDecodeOptions
}

private actor TranscriptionRuntimeFake: WhisperRuntime {
    private let outcome: TranscriptionOutcome
    private var calls: [RuntimeCall] = []

    init(outcome: TranscriptionOutcome) {
        self.outcome = outcome
    }

    func transcribe(audioURL: URL, options: WhisperDecodeOptions) async throws -> [String] {
        calls.append(RuntimeCall(audioURL: audioURL, options: options))
        switch outcome {
        case let .success(segments): return segments
        case .failure: throw TranscriptionFakeError.failed
        case .cancelled: throw CancellationError()
        }
    }

    func recordedCalls() -> [RuntimeCall] { calls }
    func callCount() -> Int { calls.count }
}

private enum TranscriptionFakeError: Error { case failed }

private actor TranscriptionBackendFake: WhisperModelBackend {
    let runtime: TranscriptionRuntimeFake

    init(runtime: TranscriptionRuntimeFake) {
        self.runtime = runtime
    }

    func isCached(_ entry: WhisperCatalogEntry, root: URL) -> Bool { true }

    func download(
        _ entry: WhisperCatalogEntry,
        root: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        throw TranscriptionFakeError.failed
    }

    func load(_ entry: WhisperCatalogEntry, root: URL) async throws -> any WhisperRuntime {
        runtime
    }

    func deleteCached(_ entry: WhisperCatalogEntry, root: URL) async throws {}
}

private struct ReadyTranscriber {
    let models: WhisperModelService
    let transcriber: WhisperTranscriber
    let lease: SpeechModelLease
    let token: EffectToken
}

private func makeReadyTranscriber(runtime: TranscriptionRuntimeFake) async throws -> ReadyTranscriber {
    let backend = TranscriptionBackendFake(runtime: runtime)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let models = try WhisperModelService(
        catalog: .bundled,
        backend: backend,
        root: root,
        clock: TranscriberTestClock()
    )
    let preparationToken = EffectToken(sessionID: SessionID(), generation: 1)
    let token = EffectToken(sessionID: SessionID(), generation: 9)
    let stream = await models.prepare(modelID: "base", token: preparationToken)
    for await _ in stream {}
    let lease = try await models.acquireReadyModel(modelID: "base", token: token)
    return ReadyTranscriber(
        models: models,
        transcriber: WhisperTranscriber(models: models),
        lease: lease,
        token: token
    )
}

private func diagnostic(_ body: () async throws -> String) async -> DiagnosticCode? {
    do {
        _ = try await body()
        return nil
    } catch let code as DiagnosticCode {
        return code
    } catch {
        return nil
    }
}
