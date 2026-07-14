import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class SpeechModelCatalogTests: XCTestCase {
    func testInjectedCatalogExposesExactPresetMappingsAndDefault() throws {
        let catalog = try WhisperModelCatalog(data: catalogData())

        XCTAssertEqual(catalog.descriptors.map(\.id), ["base", "small", "large-v3"])
        XCTAssertEqual(catalog.defaultModelID, "small")
        XCTAssertEqual(catalog.entries.map(\.folder), [
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-large-v3"
        ])
    }

    func testBundledCatalogCarriesReviewedLicensesExactSizesAndImmutableAuthorities() {
        let catalog = WhisperModelCatalog.bundled

        XCTAssertEqual(catalog.defaultModelID, "small")
        XCTAssertEqual(catalog.entries.map(\.preset), ["Fast", "Recommended", "Best Quality"])
        XCTAssertEqual(
            catalog.entries.map(\.approximateBytes),
            [149_242_445, 488_785_875, 3_091_932_457]
        )
        XCTAssertEqual(
            Set(catalog.entries.map(\.releaseEvidence)),
            ["pending-functional-verification"]
        )
        XCTAssertEqual(Set(catalog.entries.map(\.reviewStatus)), ["reviewed"])
        XCTAssertEqual(Set(catalog.entries.map(\.repository)), ["argmaxinc/whisperkit-coreml"])
        XCTAssertEqual(
            Set(catalog.entries.map(\.revision)),
            ["43ee8a5c2b72fb120079a4fb4a93f6e82057164a"]
        )
        XCTAssertEqual(Set(catalog.entries.map(\.licenseIdentifier)), ["MIT"])
        XCTAssertEqual(Set(catalog.entries.map(\.tokenizerLicenseIdentifier)), ["Apache-2.0"])
        XCTAssertEqual(catalog.entries.map(\.tokenizerRevision), [
            "e37978b90ca9030d5170a5c07aadb050351a65bb",
            "973afd24965f72e36ca33b3055d56a652f456b4d",
            "06f233fe06e710322aca913c1bc4249a0d71fce1"
        ])
    }

    func testRepositoryCatalogMatchesBundledCatalog() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Config/speech-model-catalog.json")
        )
        let repositoryCatalog = try WhisperModelCatalog(data: data)
        let bundledCatalog = WhisperModelCatalog.bundled

        XCTAssertEqual(repositoryCatalog.defaultModelID, bundledCatalog.defaultModelID)
        XCTAssertEqual(repositoryCatalog.entries, bundledCatalog.entries)
        XCTAssertEqual(repositoryCatalog.descriptors, bundledCatalog.descriptors)
    }

    func testRejectsDuplicateIDsPresetsAndInvalidDefault() throws {
        let valid = try modelObjects()

        var duplicateID = valid
        duplicateID[1]["id"] = "base"
        XCTAssertThrowsError(try WhisperModelCatalog(data: try encoded(models: duplicateID)))

        var duplicatePreset = valid
        duplicatePreset[1]["preset"] = "Fast"
        XCTAssertThrowsError(try WhisperModelCatalog(data: try encoded(models: duplicatePreset)))

        XCTAssertThrowsError(
            try WhisperModelCatalog(data: try encoded(defaultModelID: "medium", models: valid))
        )
    }

    func testRejectsEveryInvalidAuthorityFieldAndZeroSize() throws {
        let mutations: [(String, Any)] = [
            ("id", "../base"),
            ("displayName", ""),
            ("folder", "openai_whisper-small"),
            ("repository", "other/repository"),
            ("revision", "main"),
            ("revision", "ABC2e0a7895c30ff3448ec31a65eb4acffcfd7de"),
            ("sourceURL", "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/main"),
            ("licenseIdentifier", ""),
            ("licenseURL", "https://huggingface.co/argmaxinc/whisperkit-coreml/blob/main/README.md"),
            ("tokenizerRepository", "openai/other"),
            ("tokenizerRevision", "main"),
            ("tokenizerSourceURL", "https://huggingface.co/openai/whisper-base/tree/main"),
            ("tokenizerLicenseIdentifier", "MIT"),
            ("tokenizerLicenseURL", "https://huggingface.co/openai/whisper-base/blob/main/README.md"),
            ("approximateBytes", 0),
            ("approximateBytes", 149_242_444),
            ("preset", "Advanced"),
            ("releaseEvidence", "verified"),
            ("noticeObligation", ""),
            ("reviewStatus", "pending")
        ]

        for (field, value) in mutations {
            var models = try modelObjects()
            models[0][field] = value
            XCTAssertThrowsError(
                try WhisperModelCatalog(data: try encoded(models: models)),
                "field unexpectedly accepted: \(field)"
            )
        }
    }

    func testRejectsMissingPresetAndExtraOrMissingBuiltInModels() throws {
        let valid = try modelObjects()
        XCTAssertThrowsError(try WhisperModelCatalog(data: try encoded(models: Array(valid.dropLast()))))

        var extra = valid
        var fourth = valid[0]
        fourth["id"] = "medium"
        fourth["folder"] = "openai_whisper-medium"
        fourth["tokenizerRepository"] = "openai/whisper-medium"
        fourth["preset"] = "Advanced"
        extra.append(fourth)
        XCTAssertThrowsError(try WhisperModelCatalog(data: try encoded(models: extra)))
    }
}

private func catalogData() -> Data {
    try! encoded(models: validModelObjects())
}

private func modelObjects() throws -> [[String: Any]] {
    validModelObjects()
}

private func encoded(defaultModelID: String = "small", models: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "defaultModelID": defaultModelID,
        "models": models
    ], options: [.sortedKeys])
}

private func validModelObjects() -> [[String: Any]] {
    let revision = "43ee8a5c2b72fb120079a4fb4a93f6e82057164a"
    let modelLicenseURL =
        "https://huggingface.co/argmaxinc/whisperkit-coreml/blob/\(revision)/README.md"

    return [
        modelObject(
            id: "base",
            displayName: "Fast",
            folder: "openai_whisper-base",
            revision: revision,
            modelLicenseURL: modelLicenseURL,
            tokenizerRepository: "openai/whisper-base",
            tokenizerRevision: "e37978b90ca9030d5170a5c07aadb050351a65bb",
            approximateBytes: 149_242_445,
            preset: "Fast"
        ),
        modelObject(
            id: "small",
            displayName: "Recommended",
            folder: "openai_whisper-small",
            revision: revision,
            modelLicenseURL: modelLicenseURL,
            tokenizerRepository: "openai/whisper-small",
            tokenizerRevision: "973afd24965f72e36ca33b3055d56a652f456b4d",
            approximateBytes: 488_785_875,
            preset: "Recommended"
        ),
        modelObject(
            id: "large-v3",
            displayName: "Best Quality",
            folder: "openai_whisper-large-v3",
            revision: revision,
            modelLicenseURL: modelLicenseURL,
            tokenizerRepository: "openai/whisper-large-v3",
            tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
            approximateBytes: 3_091_932_457,
            preset: "Best Quality"
        )
    ]
}

private func modelObject(
    id: String,
    displayName: String,
    folder: String,
    revision: String,
    modelLicenseURL: String,
    tokenizerRepository: String,
    tokenizerRevision: String,
    approximateBytes: Int,
    preset: String
) -> [String: Any] {
    [
        "id": id,
        "displayName": displayName,
        "folder": folder,
        "repository": "argmaxinc/whisperkit-coreml",
        "revision": revision,
        "sourceURL": "https://huggingface.co/argmaxinc/whisperkit-coreml/tree/\(revision)/\(folder)",
        "licenseIdentifier": "MIT",
        "licenseURL": modelLicenseURL,
        "tokenizerRepository": tokenizerRepository,
        "tokenizerRevision": tokenizerRevision,
        "tokenizerSourceURL": "https://huggingface.co/\(tokenizerRepository)/tree/\(tokenizerRevision)",
        "tokenizerLicenseIdentifier": "Apache-2.0",
        "tokenizerLicenseURL": "https://huggingface.co/\(tokenizerRepository)/blob/\(tokenizerRevision)/README.md",
        "approximateBytes": approximateBytes,
        "preset": preset,
        "releaseEvidence": "pending-functional-verification",
        "noticeObligation": "none-runtime-download-only",
        "reviewStatus": "reviewed"
    ]
}
