import Foundation
import UtterInkCore

struct WhisperCatalogEntry: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let folder: String
    let repository: String
    let revision: String
    let tokenizerRepository: String
    let tokenizerRevision: String
    let approximateBytes: UInt64
    let preset: String
    let releaseEvidence: String
}

public struct WhisperModelCatalog: Sendable {
    public let descriptors: [SpeechModelDescriptor]

    let entries: [WhisperCatalogEntry]
    let defaultModelID: String

    public init(data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CatalogError.invalid
        }

        guard payload.defaultModelID == "small",
              payload.models.count == Self.authorities.count,
              Set(payload.models.map(\.id)).count == payload.models.count,
              Set(payload.models.map(\.preset)).count == payload.models.count else {
            throw CatalogError.invalid
        }

        for entry in payload.models {
            guard let authority = Self.authorities[entry.id],
                  entry.displayName == authority.preset,
                  entry.folder == authority.folder,
                  entry.repository == Self.modelRepository,
                  entry.revision == Self.modelRevision,
                  Self.isExactRevision(entry.revision),
                  entry.tokenizerRepository == authority.tokenizerRepository,
                  entry.tokenizerRevision == authority.tokenizerRevision,
                  Self.isExactRevision(entry.tokenizerRevision),
                  entry.approximateBytes > 0,
                  entry.preset == authority.preset,
                  entry.releaseEvidence == "pending" else {
                throw CatalogError.invalid
            }
        }

        let byID = Dictionary(uniqueKeysWithValues: payload.models.map { ($0.id, $0) })
        guard let base = byID["base"],
              let small = byID["small"],
              let large = byID["large-v3"] else {
            throw CatalogError.invalid
        }

        entries = [base, small, large]
        defaultModelID = payload.defaultModelID
        descriptors = entries.map {
            SpeechModelDescriptor(
                id: $0.id,
                displayName: $0.displayName,
                approximateBytes: $0.approximateBytes,
                preset: $0.preset
            )
        }
    }

    public static let bundled = try! WhisperModelCatalog(data: Data(Self.bundledJSON.utf8))
}

private extension WhisperModelCatalog {
    struct Payload: Codable {
        let defaultModelID: String
        let models: [WhisperCatalogEntry]
    }

    struct Authority {
        let folder: String
        let preset: String
        let tokenizerRepository: String
        let tokenizerRevision: String
    }

    enum CatalogError: Error { case invalid }

    static let modelRepository = "argmaxinc/whisperkit-coreml"
    static let modelRevision = "1f92e0a7895c30ff3448ec31a65eb4acffcfd7de"
    static let authorities: [String: Authority] = [
        "base": Authority(
            folder: "openai_whisper-base",
            preset: "Fast",
            tokenizerRepository: "openai/whisper-base",
            tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb"
        ),
        "small": Authority(
            folder: "openai_whisper-small",
            preset: "Recommended",
            tokenizerRepository: "openai/whisper-small",
            tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d"
        ),
        "large-v3": Authority(
            folder: "openai_whisper-large-v3",
            preset: "Best Quality",
            tokenizerRepository: "openai/whisper-large-v3",
            tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1"
        )
    ]

    static func isExactRevision(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            ("0" ... "9").contains(Character($0)) || ("a" ... "f").contains(Character($0))
        }
    }

    static let bundledJSON = #"{"defaultModelID":"small","models":[{"id":"base","displayName":"Fast","folder":"openai_whisper-base","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-base","tokenizerRevision":"e37978b90ca9030d5170a5c07aadb050351a65bb","approximateBytes":150000000,"preset":"Fast","releaseEvidence":"pending"},{"id":"small","displayName":"Recommended","folder":"openai_whisper-small","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-small","tokenizerRevision":"973afd24965f72e36ca33b3055d56a652f456b4d","approximateBytes":500000000,"preset":"Recommended","releaseEvidence":"pending"},{"id":"large-v3","displayName":"Best Quality","folder":"openai_whisper-large-v3","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-large-v3","tokenizerRevision":"06f233fe06e710322aca913c1bc4249a0d71fce1","approximateBytes":1600000000,"preset":"Best Quality","releaseEvidence":"pending"}]}"#
}
