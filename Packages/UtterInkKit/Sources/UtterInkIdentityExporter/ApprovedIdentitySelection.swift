import Foundation

struct ApprovedIdentitySelection: Codable, Equatable, Sendable {
    struct Approval: Codable, Equatable, Sendable {
        let evidence: String
        let reviewer: String
        let scope: String
        let status: String
        let timestamp: String
    }

    struct HashRecord: Codable, Equatable, Sendable {
        let id: String
        let sha256: String
    }

    struct PixelFit: Codable, Equatable, Sendable {
        let componentCount: Int
        let cursorHeight: Int
        let cursorWidth: Int
        let outputSHA256: String
        let pixelSize: Int
        let pointSize: Int
        let scale: Int
    }

    struct Geometry: Codable, Equatable, Sendable {
        let alphaConnectivity: Int
        let alphaThresholdExclusive: Int
        let canonicalCursorPath: String
        let cursorTranslationY: Double
        let id: String
        let pixelFit: [PixelFit]
        let resolvedCursorPath: String
        let visibleInkGapSVGUnits: Double
    }

    struct Palette: Codable, Equatable, Sendable {
        let background: String
        let id: String
        let mark: String
        let sourceSHA256: String
    }

    struct RiskReview: Codable, Equatable, Sendable {
        let competitorSimilarity: String
        let legalClearance: Bool
        let reviewDate: String
        let scope: String
    }

    struct SourceAsset: Codable, Equatable, Sendable {
        let copyrightOwner: String
        let creator: String
        let fontDependency: String?
        let id: String
        let letterformConstruction: String?
        let license: String
        let path: String
        let publicationAuthority: String
        let purpose: String
        let rightsScope: String
        let sha256: String
    }

    let approvalScope: String
    let approvalTimestamp: String
    let approvals: [Approval]
    let assetLicense: String
    let brand: String
    let canonicalInputHashes: [HashRecord]
    let copyrightOwner: String
    let geometry: Geometry
    let palette: Palette
    let riskReview: RiskReview
    let reviewer: String
    let schemaVersion: Int
    let sourceFamily: [SourceAsset]
    let status: String
    let trademarkTreatment: String
}

extension IdentityExporter {
    static func validateApprovedSelection(
        _ data: Data,
        expectedSHA256: String
    ) throws -> ApprovedIdentitySelection {
        guard !data.isEmpty, data.count <= 128 * 1_024 else {
            throw IdentityExporterError.invalidInput("approved selection size is outside its boundary")
        }
        guard sha256(data) == expectedSHA256.lowercased() else {
            throw IdentityExporterError.invalidInput("approved selection SHA-256 mismatch")
        }
        guard let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else {
            throw IdentityExporterError.invalidInput("approved selection must be canonical UTF-8")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw IdentityExporterError.invalidInput("approved selection JSON is malformed")
        }
        guard let root = object as? [String: Any] else {
            throw IdentityExporterError.invalidInput("approved selection root must be an object")
        }
        try validateApprovedSelectionShape(root)

        let selection: ApprovedIdentitySelection
        do {
            selection = try JSONDecoder().decode(ApprovedIdentitySelection.self, from: data)
        } catch {
            throw IdentityExporterError.invalidInput("approved selection fields are invalid")
        }
        try validateApprovedSelectionSemantics(selection)
        return selection
    }

    private static func validateApprovedSelectionShape(_ root: [String: Any]) throws {
        try requireKeys(root, [
            "approvalScope", "approvalTimestamp", "approvals", "assetLicense", "brand",
            "canonicalInputHashes", "copyrightOwner", "geometry", "palette", "riskReview",
            "reviewer", "schemaVersion", "sourceFamily", "status", "trademarkTreatment",
        ], label: "approved selection")

        guard let approvals = root["approvals"] as? [[String: Any]], approvals.count == 2 else {
            throw IdentityExporterError.invalidInput("approved selection requires exactly two approvals")
        }
        for approval in approvals {
            try requireKeys(approval, ["evidence", "reviewer", "scope", "status", "timestamp"], label: "approval")
        }

        guard let hashes = root["canonicalInputHashes"] as? [[String: Any]], hashes.count == 4 else {
            throw IdentityExporterError.invalidInput("canonical input hash set changed")
        }
        for hash in hashes {
            try requireKeys(hash, ["id", "sha256"], label: "canonical hash")
        }

        guard let geometry = root["geometry"] as? [String: Any] else {
            throw IdentityExporterError.invalidInput("geometry record is missing")
        }
        try requireKeys(geometry, [
            "alphaConnectivity", "alphaThresholdExclusive", "canonicalCursorPath",
            "cursorTranslationY", "id", "pixelFit", "resolvedCursorPath",
            "visibleInkGapSVGUnits",
        ], label: "geometry")
        guard let pixelFits = geometry["pixelFit"] as? [[String: Any]], pixelFits.count == 6 else {
            throw IdentityExporterError.invalidInput("pixel-fit matrix changed")
        }
        for pixelFit in pixelFits {
            try requireKeys(pixelFit, [
                "componentCount", "cursorHeight", "cursorWidth", "outputSHA256", "pixelSize",
                "pointSize", "scale",
            ], label: "pixel-fit entry")
        }

        guard let palette = root["palette"] as? [String: Any] else {
            throw IdentityExporterError.invalidInput("palette record is missing")
        }
        try requireKeys(palette, ["background", "id", "mark", "sourceSHA256"], label: "palette")

        guard let risk = root["riskReview"] as? [String: Any] else {
            throw IdentityExporterError.invalidInput("risk review is missing")
        }
        try requireKeys(risk, ["competitorSimilarity", "legalClearance", "reviewDate", "scope"], label: "risk review")

        guard let sources = root["sourceFamily"] as? [[String: Any]], sources.count == 5 else {
            throw IdentityExporterError.invalidInput("source family requires exactly five assets")
        }
        let baseKeys: Set<String> = [
            "copyrightOwner", "creator", "id", "license", "path", "publicationAuthority",
            "purpose", "rightsScope", "sha256",
        ]
        for source in sources {
            let id = source["id"] as? String
            let expected = id == "wordmark-lockup"
                ? baseKeys.union(["fontDependency", "letterformConstruction"])
                : baseKeys
            try requireKeys(source, expected, label: "source family asset")
        }
    }

    private static func validateApprovedSelectionSemantics(
        _ selection: ApprovedIdentitySelection
    ) throws {
        guard selection.schemaVersion == 2,
              selection.brand == "UtterInk",
              selection.assetLicense == "Apache-2.0",
              selection.copyrightOwner == "kthree0213",
              selection.reviewer == "kthree0213",
              selection.status == "approved-source-family-awaiting-export-lock",
              selection.approvalScope == "palette-and-pixel-fitted-menu-geometry-only",
              selection.approvalTimestamp == "2026-07-14T05:35:43Z",
              selection.trademarkTreatment == approvedTrademarkTreatment else {
            throw IdentityExporterError.invalidInput("approved selection identity contract changed")
        }

        let expectedApprovals = [
            ApprovedIdentitySelection.Approval(
                evidence: "explicit-local-user-approval",
                reviewer: "kthree0213",
                scope: "palette-and-pixel-fitted-menu-geometry-only",
                status: "approved",
                timestamp: "2026-07-14T05:35:43Z"
            ),
            ApprovedIdentitySelection.Approval(
                evidence: "explicit-local-user-approval",
                reviewer: "kthree0213",
                scope: "complete-source-family",
                status: "approved",
                timestamp: "2026-07-14T06:25:25Z"
            ),
        ]
        guard selection.approvals == expectedApprovals else {
            throw IdentityExporterError.invalidInput("both explicit local approvals are required")
        }

        let expectedCanonical = [
            ApprovedIdentitySelection.HashRecord(id: "selected-logo-route", sha256: IdentityArtifactLock.selectedRouteSHA256),
            ApprovedIdentitySelection.HashRecord(id: "identity-handoff", sha256: IdentityArtifactLock.handoffSHA256),
            ApprovedIdentitySelection.HashRecord(id: "right-cursor-vector", sha256: IdentityArtifactLock.rightCursorSHA256),
            ApprovedIdentitySelection.HashRecord(id: "menu-bar-comparison", sha256: IdentityArtifactLock.comparisonSHA256),
        ]
        guard selection.canonicalInputHashes == expectedCanonical else {
            throw IdentityExporterError.invalidInput("canonical approval inputs changed")
        }

        guard selection.palette == .init(
            background: "#171821",
            id: "night-ink",
            mark: "#F3F0E8",
            sourceSHA256: IdentityArtifactLock.palettesSHA256
        ), selection.geometry.id == "B-right-cursor-visible-gap-1B",
           selection.geometry.alphaConnectivity == 8,
           selection.geometry.alphaThresholdExclusive == 31,
           selection.geometry.canonicalCursorPath == "M18.8 4.6v3.8",
           selection.geometry.cursorTranslationY == -2,
           selection.geometry.resolvedCursorPath == "M18.8 2.6v3.8",
           selection.geometry.visibleInkGapSVGUnits == 2,
           selection.geometry.pixelFit.map(\.outputSHA256) == approvedPixelFitSHA256 else {
            throw IdentityExporterError.invalidInput("approved palette or 1B geometry changed")
        }

        guard selection.riskReview == .init(
            competitorSimilarity: "reviewed-name-amber-icon-low-to-medium",
            legalClearance: false,
            reviewDate: "2026-07-14",
            scope: "internal-knockout-not-legal-advice-or-trademark-clearance"
        ) else {
            throw IdentityExporterError.invalidInput("risk-review disclosure changed")
        }

        let expectedSources: [(String, String, String, String)] = [
            ("recording-state", "Brand/states/recording.svg", IdentityArtifactLock.recordingStateSHA256, "single-color-recording-state"),
            ("processing-state", "Brand/states/processing.svg", IdentityArtifactLock.processingStateSHA256, "single-color-processing-state"),
            ("success-state", "Brand/states/success.svg", IdentityArtifactLock.successStateSHA256, "single-color-success-state"),
            ("failure-state", "Brand/states/failure.svg", IdentityArtifactLock.failureStateSHA256, "single-color-failure-state"),
            ("wordmark-lockup", "Brand/wordmark-lockup.svg", IdentityArtifactLock.wordmarkSHA256, "deterministic-outlined-wordmark"),
        ]
        guard selection.sourceFamily.count == expectedSources.count else {
            throw IdentityExporterError.invalidInput("approved source-family count changed")
        }
        for (source, expected) in zip(selection.sourceFamily, expectedSources) {
            guard source.id == expected.0,
                  source.path == expected.1,
                  source.sha256 == expected.2,
                  source.purpose == expected.3,
                  source.creator == "kthree0213",
                  source.copyrightOwner == "kthree0213",
                  source.rightsScope == "Entire artifact",
                  source.publicationAuthority == approvedPublicationAuthority,
                  source.license == "Apache-2.0" else {
                throw IdentityExporterError.invalidInput("approved source-family rights or hashes changed")
            }
            if source.id == "wordmark-lockup" {
                guard source.fontDependency == "none",
                      source.letterformConstruction == approvedLetterformConstruction else {
                    throw IdentityExporterError.invalidInput("wordmark outline rights changed")
                }
            } else if source.fontDependency != nil || source.letterformConstruction != nil {
                throw IdentityExporterError.invalidInput("unexpected font facts on state source")
            }
        }
    }

    private static func requireKeys(
        _ object: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw IdentityExporterError.invalidInput("\(label) keys changed")
        }
    }

    private static let approvedPixelFitSHA256 = [
        "05d3546ecb8c0d9d6cebb037117e11d9da601024434ba46774ba5312c0e7514c",
        "5ac420cb08d4f3fbcf66a833e0493cad80e71f68ca894986bfc96179c75b525d",
        "d45d188df11d8dc40231de754b873e067a86cb906f8c5d6dc4997d3cbb809708",
        "f501c8a81921478521146b397c08e761a5f77f35af2645872e4d6aa610fa9dd3",
        "2c3b24bcfa4d6bb782ecf7e65cd4cca2f79e8ea6e68f1f1ed7afe4cb9a382f5f",
        "ee57d8ec22f0b4733513fd56e26aa38968203d25ac28715de6c9c510746389b6",
    ]

    private static let approvedPublicationAuthority =
        "Original creator and sole copyright holder; authorized for Apache-2.0 publication"
    private static let approvedLetterformConstruction =
        "custom SVG outlines; no third-party font file or glyph outline was copied or imported"
    private static let approvedTrademarkTreatment =
        "Apache-2.0 grants no trademark rights; UtterInk name and final production marks remain subject to separate trademark policy and final review"
}
