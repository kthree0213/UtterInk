import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import UtterInkIdentityExporter

final class IdentityExporterTests: XCTestCase {
    private let menuOutputs: [(String, Int)] = [
        ("menu-16@1x.png", 16),
        ("menu-16@2x.png", 32),
        ("menu-18@1x.png", 18),
        ("menu-18@2x.png", 36),
        ("menu-20@1x.png", 20),
        ("menu-20@2x.png", 40),
    ]

    func testExportCreatesRequiredSizesAndPixelSemantics() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputDirectory = temporaryDirectory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: outputDirectory.appendingPathComponent("stale.png"))
        let manifest = try IdentityExporter.export(
            inputs: canonicalInputs,
            outputDirectory: outputDirectory
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("stale.png").path
        ))

        for (name, size) in menuOutputs {
            let url = outputDirectory.appendingPathComponent(name)
            let image = try decodedImage(at: url)
            XCTAssertEqual(image.width, size, name)
            XCTAssertEqual(image.height, size, name)

            let pixels = try rgbaPixels(in: image)
            XCTAssertTrue(pixels.contains { $0.alpha > 0 }, "\(name) must contain a visible mark")
            XCTAssertTrue(pixels.contains { $0.alpha == 0 }, "\(name) must retain transparency")
            XCTAssertTrue(
                pixels.filter { $0.alpha > 0 }.allSatisfy { $0.red == 0 && $0.green == 0 && $0.blue == 0 },
                "\(name) must encode template artwork as black RGB plus alpha only"
            )
            try assertPNGHasNoUserOrTimeMetadata(at: url)
        }

        let palettePixels: [String: (background: (UInt8, UInt8, UInt8), mark: (UInt8, UInt8, UInt8))] = [
            "night-ink": ((23, 24, 33), (243, 240, 232)),
            "warm-paper": ((236, 230, 218), (29, 30, 37)),
            "slate": ((36, 48, 58), (238, 241, 242)),
        ]
        for palette in ["night-ink", "warm-paper", "slate"] {
            for slot in expectedAppIconSlots(palette: palette) {
                let url = outputDirectory.appendingPathComponent(slot.name)
                let image = try decodedImage(at: url)
                XCTAssertEqual(image.width, slot.size, slot.name)
                XCTAssertEqual(image.height, slot.size, slot.name)
                XCTAssertTrue(
                    try rgbaPixels(in: image).allSatisfy { $0.alpha == 255 },
                    "\(slot.name) must be fully opaque"
                )
                try assertPNGHasNoUserOrTimeMetadata(at: url)
            }

            let candidate = try rgbaPixels(
                in: decodedImage(at: outputDirectory.appendingPathComponent("appicon-\(palette)-1024.png"))
            )
            let expected = try XCTUnwrap(palettePixels[palette])
            XCTAssertTrue(candidate.contains {
                $0.red == expected.background.0
                    && $0.green == expected.background.1
                    && $0.blue == expected.background.2
            }, "\(palette) must retain its exact solid background")
            XCTAssertTrue(candidate.contains {
                $0.red == expected.mark.0
                    && $0.green == expected.mark.1
                    && $0.blue == expected.mark.2
            }, "\(palette) must contain a visible exact mark color")
            for cornerIndex in [0, 1_023, 1_023 * 1_024, 1_024 * 1_024 - 1] {
                let corner = candidate[cornerIndex]
                XCTAssertEqual(corner.red, expected.background.0)
                XCTAssertEqual(corner.green, expected.background.1)
                XCTAssertEqual(corner.blue, expected.background.2)
            }
        }

        let requiredNightIcon = try decodedImage(
            at: outputDirectory.appendingPathComponent("appicon-night-ink-1024.png")
        )
        XCTAssertEqual(requiredNightIcon.width, 1_024)
        XCTAssertEqual(requiredNightIcon.height, 1_024)

        let reviewSheet = try decodedImage(
            at: outputDirectory.appendingPathComponent("identity-review.png")
        )
        XCTAssertEqual(reviewSheet.width, 1_280)
        XCTAssertEqual(reviewSheet.height, 760)
        try assertPNGHasNoUserOrTimeMetadata(
            at: outputDirectory.appendingPathComponent("identity-review.png")
        )

        let metadataURL = outputDirectory.appendingPathComponent("identity-metadata.json")
        let metadata = try Data(contentsOf: metadataURL)
        let metadataText = try XCTUnwrap(String(data: metadata, encoding: .utf8))
        XCTAssertFalse(metadataText.contains("/Users/"))
        XCTAssertFalse(metadataText.lowercased().contains("timestamp"))
        XCTAssertFalse(metadataText.lowercased().contains("generatedat"))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: metadata))
        XCTAssertEqual(try JSONDecoder().decode(IdentityExportManifest.self, from: metadata), manifest)
        XCTAssertEqual(manifest.renderer.cubicSampleCount, 128)
        XCTAssertEqual(manifest.renderer.linearSupersamplingScale, 16)
        XCTAssertEqual(manifest.renderer.supersamplingSamplesPerPixel, 256)
        XCTAssertEqual(manifest.reviewStatus, "task-1-candidate-not-final")
        let recordedPaths = Set(manifest.outputs.map(\.path))
        let actualPNGPaths = Set(
            try relativeRegularFiles(in: outputDirectory).filter { $0.hasSuffix(".png") }
        )
        XCTAssertEqual(recordedPaths, actualPNGPaths)
        for record in manifest.outputs {
            let data = try Data(contentsOf: outputDirectory.appendingPathComponent(record.path))
            XCTAssertEqual(sha256(data), record.sha256, record.path)
            let image = try decodedImage(at: outputDirectory.appendingPathComponent(record.path))
            XCTAssertEqual(image.width, record.pixelWidth, record.path)
            XCTAssertEqual(image.height, record.pixelHeight, record.path)
        }

        let second = temporaryDirectory.appendingPathComponent("second-output", isDirectory: true)
        _ = try IdentityExporter.export(inputs: canonicalInputs, outputDirectory: second)
        let firstFiles = try relativeRegularFiles(in: outputDirectory)
        let secondFiles = try relativeRegularFiles(in: second)
        XCTAssertEqual(firstFiles, secondFiles)
        XCTAssertFalse(firstFiles.isEmpty)

        for relativePath in firstFiles {
            XCTAssertEqual(
                try Data(contentsOf: outputDirectory.appendingPathComponent(relativePath)),
                try Data(contentsOf: second.appendingPathComponent(relativePath)),
                "Non-deterministic output: \(relativePath)"
            )
        }
    }

    func testCanonicalSVGRejectsHashMismatchAndSemanticMutations() throws {
        let sourceURL = canonicalInputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg")
        let canonicalData = try Data(contentsOf: sourceURL)
        let canonicalText = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))

        XCTAssertNoThrow(
            try IdentityExporter.validateCanonicalSVG(
                canonicalData,
                expectedSHA256: sha256(canonicalData)
            )
        )
        XCTAssertThrowsError(
            try IdentityExporter.validateCanonicalSVG(
                canonicalData,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        )

        let mutations: [(String, String, String)] = [
            ("viewBox", "viewBox=\"0 0 24 24\"", "viewBox=\"0 0 25 24\""),
            ("root fill", "fill=\"none\"", "fill=\"#ffffff\""),
            ("bowl path", "M5.2 4.6v8.8", "M5.3 4.6v8.8"),
            ("cursor path", "M18.8 4.6v3.8", "M18.8 4.6v3.7"),
            ("stroke color", "stroke=\"#111111\"", "stroke=\"#121212\""),
            (
                "bowl stroke color",
                "v-2.2\" stroke=\"#111111\"",
                "v-2.2\" stroke=\"#121212\""
            ),
            (
                "cursor stroke color",
                "<path d=\"M18.8 4.6v3.8\" stroke=\"#111111\"",
                "<path d=\"M18.8 4.6v3.8\" stroke=\"#121212\""
            ),
            ("bowl width", "stroke-width=\"3.2\"", "stroke-width=\"3.1\""),
            ("cursor width", "stroke-width=\"2.4\"", "stroke-width=\"2.5\""),
            ("line cap", "stroke-linecap=\"round\"", "stroke-linecap=\"square\""),
            (
                "bowl line cap",
                "stroke-width=\"3.2\" stroke-linecap=\"round\"",
                "stroke-width=\"3.2\" stroke-linecap=\"square\""
            ),
            (
                "cursor line cap",
                "stroke-width=\"2.4\" stroke-linecap=\"round\"",
                "stroke-width=\"2.4\" stroke-linecap=\"square\""
            ),
            ("line join", "stroke-linejoin=\"round\"", "stroke-linejoin=\"bevel\""),
            ("transform", "<path d=\"M5.2", "<path transform=\"scale(1)\" d=\"M5.2"),
            ("script", "</svg>", "<script>alert(1)</script></svg>"),
            ("external image", "</svg>", "<image href=\"https://example.invalid/a.png\"/></svg>"),
            ("use reference", "</svg>", "<use href=\"#reviewed-path\"/></svg>"),
            ("font", "</svg>", "<font id=\"embedded-font\"/></svg>"),
            ("foreign object", "</svg>", "<foreignObject/></svg>"),
            ("event handler", "fill=\"none\"", "fill=\"none\" onload=\"alert(1)\""),
            ("style", "</svg>", "<style>path{display:none}</style></svg>"),
            ("comment", "<svg ", "<!-- hidden -->\n<svg "),
            ("processing instruction", "<svg ", "<?probe blocked?>\n<svg "),
            ("doctype", "<svg ", "<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>\n<svg "),
            ("extra root attribute", "fill=\"none\"", "fill=\"none\" width=\"24\""),
            (
                "third path",
                "</svg>",
                "<path d=\"M1 1v1\" stroke=\"#111111\" stroke-width=\"2.4\" stroke-linecap=\"round\"/></svg>"
            ),
        ]

        for (label, original, replacement) in mutations {
            XCTAssertTrue(canonicalText.contains(original), "Broken test fixture for \(label)")
            let mutatedText = canonicalText.replacingOccurrences(of: original, with: replacement)
            let mutatedData = try XCTUnwrap(mutatedText.data(using: .utf8))
            XCTAssertThrowsError(
                try IdentityExporter.validateCanonicalSVG(
                    mutatedData,
                    expectedSHA256: sha256(mutatedData)
                ),
                "Semantic mutation passed validation: \(label)"
            )
        }
    }

    func testParsedGeometryAndLanczosAreExplicitlyExercised() throws {
        let svgData = try Data(
            contentsOf: canonicalInputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg")
        )
        let parsed = try IdentityExporter.validateCanonicalSVG(
            svgData,
            expectedSHA256: sha256(svgData)
        )
        XCTAssertEqual(parsed.bowlSampleCount, 128)
        XCTAssertEqual(parsed.bowlPolyline.count, 131)

        var shiftedPolyline = parsed.bowlPolyline
        shiftedPolyline[0] = VectorPoint(
            x: shiftedPolyline[0].x + 0.75,
            y: shiftedPolyline[0].y
        )
        let shifted = try ValidatedSVG(
            viewBoxWidth: parsed.viewBoxWidth,
            viewBoxHeight: parsed.viewBoxHeight,
            bowlPolyline: shiftedPolyline,
            bowlSampleCount: parsed.bowlSampleCount,
            cursorStart: parsed.cursorStart,
            cursorEnd: parsed.cursorEnd,
            bowlStrokeWidth: parsed.bowlStrokeWidth,
            cursorStrokeWidth: parsed.cursorStrokeWidth
        )
        XCTAssertNotEqual(
            try IdentityRasterPipeline.renderMenu(svg: parsed, pixelSize: 20).rgba,
            try IdentityRasterPipeline.renderMenu(svg: shifted, pixelSize: 20).rgba,
            "Renderer must consume parsed geometry rather than a duplicate hard-coded path"
        )

        let transparent = try RasterImage(
            width: 16,
            height: 16,
            rgba: [UInt8](repeating: 0, count: 16 * 16 * 4)
        )
        let transparentReduced = try LanczosDownsampler.resize(
            transparent,
            width: 4,
            height: 4
        )
        XCTAssertTrue(transparentReduced.rgba.allSatisfy { $0 == 0 })

        let constantPixel: [UInt8] = [24, 48, 72, 255]
        let constant = try RasterImage(
            width: 64,
            height: 64,
            rgba: Array(repeating: constantPixel, count: 64 * 64).flatMap { $0 }
        )
        let constantReduced = try LanczosDownsampler.resize(constant, width: 8, height: 8)
        let centerOffset = (4 * 8 + 4) * 4
        XCTAssertEqual(
            Array(constantReduced.rgba[centerOffset..<(centerOffset + 4)]),
            constantPixel,
            "Lanczos must preserve a constant premultiplied plane away from zero-extended edges"
        )

        var impulseBytes = [UInt8](repeating: 0, count: 9 * 4)
        impulseBytes[4 * 4 + 3] = 255
        let impulse = try RasterImage(width: 9, height: 1, rgba: impulseBytes)
        let impulseReduced = try LanczosDownsampler.resizeAlphaMask(impulse, width: 17, height: 1)
        let impulseAlpha = stride(from: 3, to: impulseReduced.rgba.count, by: 4).map {
            impulseReduced.rgba[$0]
        }
        XCTAssertEqual(
            impulseAlpha,
            [0, 0, 0, 4, 5, 0, 0, 146, 255, 146, 0, 0, 5, 4, 0, 0, 0],
            "Golden impulse response locks Lanczos-3 lobes, clamping, symmetry, and rounding"
        )

        XCTAssertEqual(LanczosDownsampler.roundToNearestEven(2, fractionalBits: 2), 0)
        XCTAssertEqual(LanczosDownsampler.roundToNearestEven(6, fractionalBits: 2), 2)
        XCTAssertEqual(LanczosDownsampler.roundToNearestEven(-2, fractionalBits: 2), 0)
        XCTAssertEqual(LanczosDownsampler.roundToNearestEven(-6, fractionalBits: 2), -2)

        let sourceWidth = 64
        let sourceHeight = 48
        var patternedBytes = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 4)
        var patternedAlpha = [UInt8](repeating: 0, count: sourceWidth * sourceHeight)
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let alpha = UInt8((x * 17 + y * 13) % 256)
                patternedBytes[(y * sourceWidth + x) * 4 + 3] = alpha
                patternedAlpha[y * sourceWidth + x] = alpha
            }
        }
        let patterned = try RasterImage(
            width: sourceWidth,
            height: sourceHeight,
            rgba: patternedBytes
        )
        let materialized = try LanczosDownsampler.resizeAlphaMask(
            patterned,
            width: 4,
            height: 3
        )
        let streamed = try LanczosDownsampler.resizeStreamingAlphaMask(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            width: 4,
            height: 3
        ) { sourceY in
            let start = sourceY * sourceWidth
            return patternedAlpha[start..<(start + sourceWidth)]
        }
        XCTAssertEqual(streamed, materialized)
    }

    func testOutputPublicationReplacesExistingDirectoryWithoutStaleFiles() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("published", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("stale.txt"))

        let publication = try OutputPublication(destination: destination)
        defer { publication.discardIfNeeded() }
        try Data("current".utf8).write(
            to: publication.stagingDirectory.appendingPathComponent("current.txt")
        )
        try publication.commit()

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("current.txt")),
            Data("current".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.txt").path)
        )
        let stagingPrefix = ".\(destination.lastPathComponent).utterink-staging-"
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
                .contains { $0.hasPrefix(stagingPrefix) }
        )
    }

    func testOutputPublicationRollbackRemovesNewDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("published", isDirectory: true)
        let publication = try OutputPublication(destination: destination)
        defer { publication.discardIfNeeded() }
        try Data("current".utf8).write(
            to: publication.stagingDirectory.appendingPathComponent("current.txt")
        )

        try publication.commitKeepingPrior()
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try publication.rollbackCommit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testOutputPublicationRollbackRestoresExistingDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("published", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: destination.appendingPathComponent("prior.txt"))

        let publication = try OutputPublication(destination: destination)
        defer { publication.discardIfNeeded() }
        try Data("current".utf8).write(
            to: publication.stagingDirectory.appendingPathComponent("current.txt")
        )

        try publication.commitKeepingPrior()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("prior.txt").path)
        )

        try publication.rollbackCommit()
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("prior.txt")),
            Data("prior".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("current.txt").path)
        )
    }

    func testOutputPublicationRollbackCleanupFailureNeverRepublishesNewDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("published", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: destination.appendingPathComponent("prior.txt"))

        var injectedFailures = 1
        let publication = try OutputPublication(destination: destination) { url in
            if injectedFailures > 0 {
                injectedFailures -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.removeItem(at: url)
        }
        defer { publication.discardIfNeeded() }
        try Data("current".utf8).write(
            to: publication.stagingDirectory.appendingPathComponent("current.txt")
        )

        try publication.commitKeepingPrior()
        XCTAssertThrowsError(try publication.rollbackCommit())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("prior.txt")),
            Data("prior".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("current.txt").path)
        )

        publication.discardIfNeeded()
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("prior.txt")),
            Data("prior".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: publication.stagingDirectory.path))
    }

    func testOutputPublicationFinalizeCleanupFailureKeepsPublishedDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let destination = temporaryDirectory.appendingPathComponent("published", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: destination.appendingPathComponent("prior.txt"))

        var injectedFailures = 1
        let publication = try OutputPublication(destination: destination) { url in
            if injectedFailures > 0 {
                injectedFailures -= 1
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.removeItem(at: url)
        }
        defer { publication.discardIfNeeded() }
        try Data("current".utf8).write(
            to: publication.stagingDirectory.appendingPathComponent("current.txt")
        )

        XCTAssertThrowsError(try publication.commit())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("current.txt")),
            Data("current".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.appendingPathComponent("prior.txt").path)
        )

        publication.discardIfNeeded()
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("current.txt")),
            Data("current".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: publication.stagingDirectory.path))
    }

    func testSecureFileReaderRejectsOversizedAndSpecialFiles() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let oversized = temporaryDirectory.appendingPathComponent("oversized.bin")
        try Data(repeating: 0x41, count: 17).write(to: oversized)
        XCTAssertThrowsError(
            try SecureFileReader.readRegularFile(
                at: oversized,
                limit: 16,
                displayName: "oversized fixture"
            )
        )

        let fifo = temporaryDirectory.appendingPathComponent("input.fifo")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertThrowsError(
            try SecureFileReader.readRegularFile(
                at: fifo,
                limit: 16,
                displayName: "FIFO fixture"
            )
        )
    }

    func testProvenanceAllowsMissingLocalMontageButRejectsMismatchAndMissingRights() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureRoot = temporaryDirectory.appendingPathComponent("fixture", isDirectory: true)
        let inputs = try copyTrackedIdentityFixture(to: fixtureRoot)
        XCTAssertNoThrow(try IdentityExporter.validateProvenance(inputs: inputs))

        let comparisonURL = fixtureRoot
            .appendingPathComponent("dist/identity-input-review", isDirectory: true)
            .appendingPathComponent("menu-bar-comparison.png")
        try FileManager.default.createDirectory(
            at: comparisonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not the reviewed montage".utf8).write(to: comparisonURL)
        XCTAssertThrowsError(try IdentityExporter.validateProvenance(inputs: inputs))

        try FileManager.default.removeItem(at: comparisonURL)
        let provenanceURL = inputs.sourceDirectory.appendingPathComponent("provenance.json")
        let provenanceData = try Data(contentsOf: provenanceURL)
        var provenance = try XCTUnwrap(
            JSONSerialization.jsonObject(with: provenanceData) as? [String: Any]
        )
        var artifacts = try XCTUnwrap(provenance["artifacts"] as? [[String: Any]])
        XCTAssertNotNil(artifacts[0].removeValue(forKey: "rightsScope"))
        provenance["artifacts"] = artifacts
        let strippedData = try JSONSerialization.data(
            withJSONObject: provenance,
            options: [.prettyPrinted, .sortedKeys]
        )
        try strippedData.write(to: provenanceURL)
        XCTAssertThrowsError(try IdentityExporter.validateProvenance(inputs: inputs))
    }

    func testProvenanceRejectsSymlinkedPublicInput() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureRoot = temporaryDirectory.appendingPathComponent("fixture", isDirectory: true)
        let inputs = try copyTrackedIdentityFixture(to: fixtureRoot)
        let copiedSVG = inputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg")
        try FileManager.default.removeItem(at: copiedSVG)
        try FileManager.default.createSymbolicLink(
            at: copiedSVG,
            withDestinationURL: canonicalInputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg")
        )

        XCTAssertThrowsError(try IdentityExporter.validateProvenance(inputs: inputs))
    }

    func testProvenanceLocksExactContractsAndRejectsUnsafeValues() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let mutations: [(artifact: Int, key: String, value: Any)] = [
            (0, "sha256", String(repeating: "0", count: 64)),
            (1, "id", "selected-logo-route"),
            (0, "path", "/tmp/selected-logo-route.json"),
            (0, "path", "Brand/../selected-logo-route.json"),
            (0, "path", "~/selected-logo-route.json"),
            (0, "path", "Brand/./Source/selected-logo-route.json"),
            (0, "reviewer", ""),
            (1, "purpose", "TBD"),
            (2, "publicationAuthority", "unknown"),
            (3, "publicDistribution", true),
            (3, "rightsScope", "Entire artifact"),
        ]

        for (index, mutation) in mutations.enumerated() {
            let root = temporaryDirectory.appendingPathComponent("mutation-\(index)", isDirectory: true)
            let inputs = try copyTrackedIdentityFixture(to: root)
            let provenanceURL = inputs.sourceDirectory.appendingPathComponent("provenance.json")
            var document = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: provenanceURL)) as? [String: Any]
            )
            var artifacts = try XCTUnwrap(document["artifacts"] as? [[String: Any]])
            artifacts[mutation.artifact][mutation.key] = mutation.value
            document["artifacts"] = artifacts
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: provenanceURL)
            XCTAssertThrowsError(
                try IdentityExporter.validateProvenance(inputs: inputs),
                "Unsafe provenance mutation passed: \(mutation.key)=\(mutation.value)"
            )
        }

        let countRoot = temporaryDirectory.appendingPathComponent("extra-artifact", isDirectory: true)
        let countInputs = try copyTrackedIdentityFixture(to: countRoot)
        let countURL = countInputs.sourceDirectory.appendingPathComponent("provenance.json")
        var countDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: countURL)) as? [String: Any]
        )
        var countArtifacts = try XCTUnwrap(countDocument["artifacts"] as? [[String: Any]])
        countArtifacts.append(countArtifacts[0])
        countDocument["artifacts"] = countArtifacts
        try JSONSerialization.data(withJSONObject: countDocument, options: [.sortedKeys]).write(to: countURL)
        XCTAssertThrowsError(try IdentityExporter.validateProvenance(inputs: countInputs))

        let bytesRoot = temporaryDirectory.appendingPathComponent("changed-public-bytes", isDirectory: true)
        let bytesInputs = try copyTrackedIdentityFixture(to: bytesRoot)
        let selectedRoute = bytesInputs.sourceDirectory.appendingPathComponent("selected-logo-route.json")
        var changedBytes = try Data(contentsOf: selectedRoute)
        changedBytes.append(0x0a)
        try changedBytes.write(to: selectedRoute)
        XCTAssertThrowsError(try IdentityExporter.validateProvenance(inputs: bytesInputs))
    }
}

private extension IdentityExporterTests {
    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    var canonicalInputs: IdentityInputPaths {
        IdentityInputPaths(
            sourceDirectory: repositoryRoot.appendingPathComponent("Brand/Source", isDirectory: true),
            paletteFile: repositoryRoot.appendingPathComponent("Brand/palettes.json")
        )
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UtterInkIdentityExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func expectedAppIconSlots(palette: String) -> [(name: String, size: Int)] {
        [
            ("appicon-\(palette)-16x16@1x.png", 16),
            ("appicon-\(palette)-16x16@2x.png", 32),
            ("appicon-\(palette)-32x32@1x.png", 32),
            ("appicon-\(palette)-32x32@2x.png", 64),
            ("appicon-\(palette)-128x128@1x.png", 128),
            ("appicon-\(palette)-128x128@2x.png", 256),
            ("appicon-\(palette)-256x256@1x.png", 256),
            ("appicon-\(palette)-256x256@2x.png", 512),
            ("appicon-\(palette)-512x512@1x.png", 512),
            ("appicon-\(palette)-1024.png", 1_024),
        ]
    }

    func decodedImage(at url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "Unreadable PNG: \(url.path)")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "Undecodable PNG: \(url.path)")
    }

    func rgbaPixels(in image: CGImage) throws -> [Pixel] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            )
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return stride(from: 0, to: bytes.count, by: 4).map {
            Pixel(red: bytes[$0], green: bytes[$0 + 1], blue: bytes[$0 + 2], alpha: bytes[$0 + 3])
        }
    }

    func assertPNGHasNoUserOrTimeMetadata(at url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let chunkTypes = try pngChunkTypes(at: url)
        XCTAssertEqual(chunkTypes.first, "IHDR", file: file, line: line)
        XCTAssertEqual(chunkTypes.last, "IEND", file: file, line: line)
        let forbiddenChunks: Set<String> = ["tEXt", "zTXt", "iTXt", "tIME"]
        XCTAssertTrue(
            forbiddenChunks.isDisjoint(with: chunkTypes),
            "Forbidden PNG chunks \(forbiddenChunks.intersection(chunkTypes)) in \(url.lastPathComponent)",
            file: file,
            line: line
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        let keys = flattenedPropertyKeys(properties)
        let forbiddenFragments = [
            "datetime", "timestamp", "usercomment", "gps", "tiff", "iptc", "makernote",
            "hostcomputer", "software", "title", "author", "description", "copyright",
        ]
        for key in keys {
            XCTAssertFalse(
                forbiddenFragments.contains { key.lowercased().contains($0) },
                "Forbidden PNG metadata key \(key) in \(url.lastPathComponent)",
                file: file,
                line: line
            )
        }
    }

    func pngChunkTypes(at url: URL) throws -> [String] {
        let bytes = [UInt8](try Data(contentsOf: url))
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= signature.count, Array(bytes.prefix(8)) == signature else {
            throw PNGFixtureError.invalidSignature
        }

        var chunkTypes: [String] = []
        var offset = 8
        var sawEnd = false
        while offset < bytes.count {
            guard bytes.count - offset >= 12 else {
                throw PNGFixtureError.truncatedChunk
            }
            let length = bytes[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let payloadLength = Int(length)
            guard payloadLength <= bytes.count - offset - 12 else {
                throw PNGFixtureError.truncatedChunk
            }
            let chunkEnd = offset + 12 + payloadLength
            let typeBytes = bytes[(offset + 4)..<(offset + 8)]
            guard let type = String(bytes: typeBytes, encoding: .ascii), type.count == 4 else {
                throw PNGFixtureError.invalidChunkType
            }
            chunkTypes.append(type)
            offset = chunkEnd
            if type == "IEND" {
                sawEnd = true
                break
            }
        }
        guard sawEnd, offset == bytes.count else {
            throw PNGFixtureError.trailingOrMissingEnd
        }
        return chunkTypes
    }

    func flattenedPropertyKeys(_ value: Any) -> [String] {
        if let dictionary = value as? NSDictionary {
            return dictionary.flatMap { key, nestedValue in
                [String(describing: key)] + flattenedPropertyKeys(nestedValue)
            }
        }
        if let array = value as? NSArray {
            return array.flatMap { flattenedPropertyKeys($0) }
        }
        return []
    }

    func relativeRegularFiles(in root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let resolvedRootComponents = root.resolvingSymlinksInPath().pathComponents
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        )
        var files: [String] = []
        for case let fileURL as URL in enumerator {
            if try fileURL.resourceValues(forKeys: Set(keys)).isRegularFile == true {
                let components = fileURL.resolvingSymlinksInPath().pathComponents
                guard components.starts(with: resolvedRootComponents) else {
                    XCTFail("Enumerated file escaped output root: \(fileURL.path)")
                    continue
                }
                files.append(components.dropFirst(resolvedRootComponents.count).joined(separator: "/"))
            }
        }
        return files.sorted()
    }

    func copyTrackedIdentityFixture(to root: URL) throws -> IdentityInputPaths {
        let sourceDirectory = root.appendingPathComponent("Brand/Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

        for name in [
            "selected-logo-route.json",
            "identity-handoff.md",
            "B-right-cursor.svg",
            "provenance.json",
        ] {
            try FileManager.default.copyItem(
                at: canonicalInputs.sourceDirectory.appendingPathComponent(name),
                to: sourceDirectory.appendingPathComponent(name)
            )
        }

        let paletteFile = root.appendingPathComponent("Brand/palettes.json")
        try FileManager.default.copyItem(at: canonicalInputs.paletteFile, to: paletteFile)
        return IdentityInputPaths(sourceDirectory: sourceDirectory, paletteFile: paletteFile)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum PNGFixtureError: Error {
    case invalidSignature
    case truncatedChunk
    case invalidChunkType
    case trailingOrMissingEnd
}
