import Foundation
import UtterInkCore

public actor WhisperTranscriber: TranscriptionService {
    private let models: WhisperModelService

    public init(models: WhisperModelService) {
        self.models = models
    }

    public func transcribe(
        audioURL: URL,
        model: SpeechModelLease,
        configuration: RecognitionConfiguration,
        token: EffectToken
    ) async throws -> String {
        guard !Task.isCancelled else { throw DiagnosticCode.cancelled }

        let runtime: any WhisperRuntime
        do {
            runtime = try await models.resolve(model, token: token)
        } catch is CancellationError {
            throw DiagnosticCode.cancelled
        } catch {
            throw DiagnosticCode.transcriptionFailed
        }

        let options: WhisperDecodeOptions
        switch configuration {
        case .automatic:
            options = WhisperDecodeOptions(language: nil, detectLanguage: true)
        case let .fixed(languageCode):
            options = WhisperDecodeOptions(language: languageCode, detectLanguage: false)
        }

        let segments: [String]
        do {
            segments = try await runtime.transcribe(audioURL: audioURL, options: options)
        } catch is CancellationError {
            throw DiagnosticCode.cancelled
        } catch {
            throw DiagnosticCode.transcriptionFailed
        }
        guard !Task.isCancelled else { throw DiagnosticCode.cancelled }

        let text = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { throw DiagnosticCode.transcriptionEmpty }
        return text
    }
}
