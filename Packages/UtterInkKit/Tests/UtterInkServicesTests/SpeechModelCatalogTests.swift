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

    func testBundledCatalogCarriesOnlyPendingEvidenceAndImmutableAuthorities() {
        let catalog = WhisperModelCatalog.bundled

        XCTAssertEqual(catalog.defaultModelID, "small")
        XCTAssertEqual(catalog.entries.map(\.preset), ["Fast", "Recommended", "Best Quality"])
        XCTAssertEqual(Set(catalog.entries.map(\.releaseEvidence)), ["pending"])
        XCTAssertEqual(Set(catalog.entries.map(\.repository)), ["argmaxinc/whisperkit-coreml"])
        XCTAssertEqual(
            Set(catalog.entries.map(\.revision)),
            ["1f92e0a7895c30ff3448ec31a65eb4acffcfd7de"]
        )
        XCTAssertEqual(catalog.entries.map(\.tokenizerRevision), [
            "e37978b90ca9030d5170a5c07aadb050351a65bb",
            "973afd24965f72e36ca33b3055d56a652f456b4d",
            "06f233fe06e710322aca913c1bc4249a0d71fce1"
        ])
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
            ("tokenizerRepository", "openai/other"),
            ("tokenizerRevision", "main"),
            ("approximateBytes", 0),
            ("preset", "Advanced"),
            ("releaseEvidence", "verified")
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
    Data(
        #"{"defaultModelID":"small","models":[{"id":"base","displayName":"Fast","folder":"openai_whisper-base","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-base","tokenizerRevision":"e37978b90ca9030d5170a5c07aadb050351a65bb","approximateBytes":150000000,"preset":"Fast","releaseEvidence":"pending"},{"id":"small","displayName":"Recommended","folder":"openai_whisper-small","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-small","tokenizerRevision":"973afd24965f72e36ca33b3055d56a652f456b4d","approximateBytes":500000000,"preset":"Recommended","releaseEvidence":"pending"},{"id":"large-v3","displayName":"Best Quality","folder":"openai_whisper-large-v3","repository":"argmaxinc/whisperkit-coreml","revision":"1f92e0a7895c30ff3448ec31a65eb4acffcfd7de","tokenizerRepository":"openai/whisper-large-v3","tokenizerRevision":"06f233fe06e710322aca913c1bc4249a0d71fce1","approximateBytes":1600000000,"preset":"Best Quality","releaseEvidence":"pending"}]}"#.utf8
    )
}

private func modelObjects() throws -> [[String: Any]] {
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData()) as? [String: Any])
    return try XCTUnwrap(object["models"] as? [[String: Any]])
}

private func encoded(defaultModelID: String = "small", models: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "defaultModelID": defaultModelID,
        "models": models
    ], options: [.sortedKeys])
}
