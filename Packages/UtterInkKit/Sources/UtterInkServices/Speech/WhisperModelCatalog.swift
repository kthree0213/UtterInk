import Foundation
import UtterInkCore

struct WhisperCatalogEntry: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let folder: String
    let repository: String
    let revision: String
    let sourceURL: String
    let licenseIdentifier: String
    let licenseURL: String
    let tokenizerRepository: String
    let tokenizerRevision: String
    let tokenizerSourceURL: String
    let tokenizerLicenseIdentifier: String
    let tokenizerLicenseURL: String
    let approximateBytes: UInt64
    let preset: String
    let releaseEvidence: String
    let noticeObligation: String
    let reviewStatus: String
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
                  entry.sourceURL == Self.modelSourceURL(folder: authority.folder),
                  entry.licenseIdentifier == Self.modelLicenseIdentifier,
                  entry.licenseURL == Self.modelLicenseURL,
                  entry.tokenizerRepository == authority.tokenizerRepository,
                  entry.tokenizerRevision == authority.tokenizerRevision,
                  Self.isExactRevision(entry.tokenizerRevision),
                  entry.tokenizerSourceURL == Self.tokenizerSourceURL(authority),
                  entry.tokenizerLicenseIdentifier == Self.tokenizerLicenseIdentifier,
                  entry.tokenizerLicenseURL == Self.tokenizerLicenseURL(authority),
                  entry.approximateBytes == authority.approximateBytes,
                  entry.preset == authority.preset,
                  entry.releaseEvidence == Self.releaseEvidence,
                  entry.noticeObligation == Self.noticeObligation,
                  entry.reviewStatus == Self.reviewStatus else {
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
        let approximateBytes: UInt64
    }

    enum CatalogError: Error { case invalid }

    static let modelRepository = "argmaxinc/whisperkit-coreml"
    static let modelRevision = "43ee8a5c2b72fb120079a4fb4a93f6e82057164a"
    static let modelLicenseIdentifier = "MIT"
    static let modelLicenseURL =
        "https://huggingface.co/argmaxinc/whisperkit-coreml/blob/\(modelRevision)/README.md"
    static let tokenizerLicenseIdentifier = "Apache-2.0"
    static let releaseEvidence = "pending-functional-verification"
    static let noticeObligation = "none-runtime-download-only"
    static let reviewStatus = "reviewed"
    static let authorities: [String: Authority] = [
        "base": Authority(
            folder: "openai_whisper-base",
            preset: "Fast",
            tokenizerRepository: "openai/whisper-base",
            tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb",
            approximateBytes: 149_242_445
        ),
        "small": Authority(
            folder: "openai_whisper-small",
            preset: "Recommended",
            tokenizerRepository: "openai/whisper-small",
            tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d",
            approximateBytes: 488_785_875
        ),
        "large-v3": Authority(
            folder: "openai_whisper-large-v3",
            preset: "Best Quality",
            tokenizerRepository: "openai/whisper-large-v3",
            tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
            approximateBytes: 3_091_932_457
        )
    ]

    static func modelSourceURL(folder: String) -> String {
        "https://huggingface.co/\(modelRepository)/tree/\(modelRevision)/\(folder)"
    }

    static func tokenizerSourceURL(_ authority: Authority) -> String {
        "https://huggingface.co/\(authority.tokenizerRepository)/tree/\(authority.tokenizerRevision)"
    }

    static func tokenizerLicenseURL(_ authority: Authority) -> String {
        "https://huggingface.co/\(authority.tokenizerRepository)/blob/\(authority.tokenizerRevision)/README.md"
    }

    static func isExactRevision(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            ("0" ... "9").contains(Character($0)) || ("a" ... "f").contains(Character($0))
        }
    }

    static let bundledJSON = #"{"defaultModelID":"small","models":[{"id":"base","displayName":"Fast","folder":"openai_whisper-base","repository":"argmaxinc/whisperkit-coreml","revision":"43ee8a5c2b72fb120079a4fb4a93f6e82057164a","sourceURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-base","licenseIdentifier":"MIT","licenseURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md","tokenizerRepository":"openai/whisper-base","tokenizerRevision":"e37978b90ca9030d5170a5c07aadb050351a65bb","tokenizerSourceURL":"https://huggingface.co/openai/whisper-base/tree/e37978b90ca9030d5170a5c07aadb050351a65bb","tokenizerLicenseIdentifier":"Apache-2.0","tokenizerLicenseURL":"https://huggingface.co/openai/whisper-base/blob/e37978b90ca9030d5170a5c07aadb050351a65bb/README.md","approximateBytes":149242445,"preset":"Fast","releaseEvidence":"pending-functional-verification","noticeObligation":"none-runtime-download-only","reviewStatus":"reviewed"},{"id":"small","displayName":"Recommended","folder":"openai_whisper-small","repository":"argmaxinc/whisperkit-coreml","revision":"43ee8a5c2b72fb120079a4fb4a93f6e82057164a","sourceURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-small","licenseIdentifier":"MIT","licenseURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md","tokenizerRepository":"openai/whisper-small","tokenizerRevision":"973afd24965f72e36ca33b3055d56a652f456b4d","tokenizerSourceURL":"https://huggingface.co/openai/whisper-small/tree/973afd24965f72e36ca33b3055d56a652f456b4d","tokenizerLicenseIdentifier":"Apache-2.0","tokenizerLicenseURL":"https://huggingface.co/openai/whisper-small/blob/973afd24965f72e36ca33b3055d56a652f456b4d/README.md","approximateBytes":488785875,"preset":"Recommended","releaseEvidence":"pending-functional-verification","noticeObligation":"none-runtime-download-only","reviewStatus":"reviewed"},{"id":"large-v3","displayName":"Best Quality","folder":"openai_whisper-large-v3","repository":"argmaxinc/whisperkit-coreml","revision":"43ee8a5c2b72fb120079a4fb4a93f6e82057164a","sourceURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/tree/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/openai_whisper-large-v3","licenseIdentifier":"MIT","licenseURL":"https://huggingface.co/argmaxinc/whisperkit-coreml/blob/43ee8a5c2b72fb120079a4fb4a93f6e82057164a/README.md","tokenizerRepository":"openai/whisper-large-v3","tokenizerRevision":"06f233fe06e710322aca913c1bc4249a0d71fce1","tokenizerSourceURL":"https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1","tokenizerLicenseIdentifier":"Apache-2.0","tokenizerLicenseURL":"https://huggingface.co/openai/whisper-large-v3/blob/06f233fe06e710322aca913c1bc4249a0d71fce1/README.md","approximateBytes":3091932457,"preset":"Best Quality","releaseEvidence":"pending-functional-verification","noticeObligation":"none-runtime-download-only","reviewStatus":"reviewed"}]}"#
}
