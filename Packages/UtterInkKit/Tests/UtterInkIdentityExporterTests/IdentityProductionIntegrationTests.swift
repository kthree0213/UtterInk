import CryptoKit
import Foundation
import XCTest
@testable import UtterInkIdentityExporter

final class IdentityProductionIntegrationTests: XCTestCase {
    func testApprovedSelectionRequiresBothApprovalsAndFiveLockedSources() throws {
        let selectionURL = repositoryRoot.appendingPathComponent("Brand/identity-selection.json")
        let data = try Data(contentsOf: selectionURL)
        let selection = try IdentityExporter.validateApprovedSelection(
            data,
            expectedSHA256: sha256(data)
        )

        XCTAssertEqual(selection.approvals.map(\.scope), [
            "palette-and-pixel-fitted-menu-geometry-only",
            "complete-source-family",
        ])
        XCTAssertEqual(selection.sourceFamily.count, 5)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var approvals = try XCTUnwrap(object["approvals"] as? [[String: Any]])
        approvals.removeLast()
        object["approvals"] = approvals
        let missingApproval = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try IdentityExporter.validateApprovedSelection(
                missingApproval,
                expectedSHA256: sha256(missingApproval)
            )
        )

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sources = try XCTUnwrap(object["sourceFamily"] as? [[String: Any]])
        sources[0]["sha256"] = String(repeating: "0", count: 64)
        object["sourceFamily"] = sources
        let tamperedSource = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(
            try IdentityExporter.validateApprovedSelection(
                tamperedSource,
                expectedSHA256: sha256(tamperedSource)
            )
        )
    }

    func testIntegrateCreatesLockedCatalogAndCheckDoesNotMutateIt() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixtureRoot = temporaryDirectory.appendingPathComponent("fixture", isDirectory: true)
        let request = try copyProductionFixture(to: fixtureRoot)

        let legacyDirectory = request.assetCatalog.appendingPathComponent("Legacy.imageset", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try Data("preserved".utf8).write(to: legacyDirectory.appendingPathComponent("legacy.txt"))

        let lock = try IdentityExporter.integrateProductionIdentity(
            request: request,
            configuration: .testing
        )
        XCTAssertEqual(lock.status, "production-assets-locked")
        XCTAssertEqual(lock.approvals.count, 2)
        XCTAssertEqual(lock.palette.id, "night-ink")
        XCTAssertEqual(lock.geometry.id, "B-right-cursor-visible-gap-1B")
        XCTAssertEqual(lock.geometry.pixelFit.count, 6)
        XCTAssertEqual(lock.selection.id, "approved-identity-selection")
        XCTAssertEqual(lock.renderer.linearSupersamplingScale, 1)
        XCTAssertEqual(lock.renderer.toolchainContract, "test-toolchain")
        XCTAssertEqual(lock.outputs.count, 37)
        XCTAssertTrue(lock.outputs.contains { $0.path == "Legacy.imageset/legacy.txt" })
        XCTAssertTrue(lock.outputs.contains { $0.path == "AppIcon.appiconset/appicon-512x512@2x.png" })
        XCTAssertTrue(lock.outputs.contains { $0.path == "MenuBarIcon.imageset/MenuBarIcon@2x.png" })
        XCTAssertTrue(lock.outputs.contains { $0.path == "BrandMark.imageset/BrandMark@2x.png" })
        XCTAssertTrue(lock.outputs.contains { $0.path == "StatusFailure.imageset/StatusFailure@2x.png" })
        XCTAssertFalse(lock.outputs.contains { $0.path.contains("warm-paper") || $0.path.contains("slate") })

        let lockData = try Data(contentsOf: request.lockFile)
        XCTAssertEqual(try JSONDecoder().decode(IdentityProductionLock.self, from: lockData), lock)
        let lockText = try XCTUnwrap(String(data: lockData, encoding: .utf8))
        XCTAssertFalse(lockText.contains("/Users/"))
        XCTAssertFalse(lockText.lowercased().contains("generatedat"))

        let before = try recursiveBytes(in: fixtureRoot)
        try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        XCTAssertEqual(try recursiveBytes(in: fixtureRoot), before)

        var unknownKeyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lockData) as? [String: Any]
        )
        unknownKeyObject["unexpected"] = true
        try writeJSONObject(unknownKeyObject, to: request.lockFile)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(error as? IdentityExporterError, .mismatchedFiles(["Brand/identity-lock.json"]))
        }
        try lockData.write(to: request.lockFile)

        var nestedKeyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lockData) as? [String: Any]
        )
        var lockedGeometry = try XCTUnwrap(nestedKeyObject["geometry"] as? [String: Any])
        lockedGeometry["unexpected"] = true
        nestedKeyObject["geometry"] = lockedGeometry
        try writeJSONObject(nestedKeyObject, to: request.lockFile)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(error as? IdentityExporterError, .mismatchedFiles(["Brand/identity-lock.json"]))
        }
        try lockData.write(to: request.lockFile)

        var selectionIDObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lockData) as? [String: Any]
        )
        var lockedSelection = try XCTUnwrap(selectionIDObject["selection"] as? [String: Any])
        lockedSelection["id"] = "changed-selection"
        selectionIDObject["selection"] = lockedSelection
        try writeJSONObject(selectionIDObject, to: request.lockFile)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(error as? IdentityExporterError, .mismatchedFiles(["Brand/identity-lock.json"]))
        }
        try lockData.write(to: request.lockFile)

        var aggregateObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: lockData) as? [String: Any]
        )
        aggregateObject["exporterAggregateSHA256"] = String(repeating: "0", count: 64)
        try writeJSONObject(aggregateObject, to: request.lockFile)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(error as? IdentityExporterError, .mismatchedFiles(["Brand/identity-lock.json"]))
        }
        try lockData.write(to: request.lockFile)

        var lockObject = try XCTUnwrap(JSONSerialization.jsonObject(with: lockData) as? [String: Any])
        var renderer = try XCTUnwrap(lockObject["renderer"] as? [String: Any])
        renderer["lanczosRadius"] = 2
        lockObject["renderer"] = renderer
        var mutatedLock = try JSONSerialization.data(
            withJSONObject: lockObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        mutatedLock.append(0x0a)
        try mutatedLock.write(to: request.lockFile)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(error as? IdentityExporterError, .mismatchedFiles(["Brand/identity-lock.json"]))
        }
        try lockData.write(to: request.lockFile)
        try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)

        let source = fixtureRoot.appendingPathComponent("Brand/states/success.svg")
        let sourceData = try Data(contentsOf: source)
        var changedSourceData = sourceData
        changedSourceData.append(0x0a)
        try changedSourceData.write(to: source)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(
                error as? IdentityExporterError,
                .mismatchedFiles(["Brand/states/success.svg"])
            )
        }
        try sourceData.write(to: source)
        try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)

        let unsafeCatalogEntry = request.assetCatalog.appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(
            at: unsafeCatalogEntry,
            withDestinationURL: request.assetCatalog.appendingPathComponent("Contents.json")
        )
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(
                error as? IdentityExporterError,
                .mismatchedFiles(["App/Resources/Assets.xcassets/unsafe-link"])
            )
        }
        try FileManager.default.removeItem(at: unsafeCatalogEntry)

        let tampered = request.assetCatalog
            .appendingPathComponent("MenuBarIcon.imageset/MenuBarIcon@1x.png")
        var bytes = try Data(contentsOf: tampered)
        bytes.append(0)
        try bytes.write(to: tampered)
        XCTAssertThrowsError(
            try IdentityExporter.checkProductionIdentity(request: request, configuration: .testing)
        ) { error in
            XCTAssertEqual(
                error as? IdentityExporterError,
                .mismatchedFiles([
                    "App/Resources/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon@1x.png",
                ])
            )
        }
    }

    func testIntegrateRejectsMissingSourceWithoutPublishingCatalogOrLock() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixtureRoot = temporaryDirectory.appendingPathComponent("fixture", isDirectory: true)
        let request = try copyProductionFixture(to: fixtureRoot)
        try FileManager.default.removeItem(
            at: fixtureRoot.appendingPathComponent("Brand/wordmark-lockup.svg")
        )

        XCTAssertThrowsError(
            try IdentityExporter.integrateProductionIdentity(request: request, configuration: .testing)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.assetCatalog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.lockFile.path))

        let tamperRoot = temporaryDirectory.appendingPathComponent("tampered", isDirectory: true)
        let tamperRequest = try copyProductionFixture(to: tamperRoot)
        let state = tamperRoot.appendingPathComponent("Brand/states/success.svg")
        var stateData = try Data(contentsOf: state)
        stateData.append(0x0a)
        try stateData.write(to: state)
        XCTAssertThrowsError(
            try IdentityExporter.integrateProductionIdentity(
                request: tamperRequest,
                configuration: .testing
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperRequest.assetCatalog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tamperRequest.lockFile.path))
    }

    func testIntegrateRollsBackCatalogChangedAtAtomicPublicationBoundary() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fixtureRoot = temporaryDirectory.appendingPathComponent("fixture", isDirectory: true)
        let request = try copyProductionFixture(to: fixtureRoot)
        let legacyDirectory = request.assetCatalog.appendingPathComponent(
            "Legacy.imageset",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("legacy.txt")
        try Data("baseline".utf8).write(to: legacyFile)

        XCTAssertThrowsError(
            try IdentityExporter.integrateProductionIdentity(
                request: request,
                configuration: .testing,
                publicationBoundaryHook: {
                    try Data("editor-change".utf8).write(to: legacyFile)
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: legacyFile), Data("editor-change".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.lockFile.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: request.assetCatalog.appendingPathComponent("AppIcon.appiconset").path
            )
        )
    }

    func testApprovedStatesUseSixSizeMatrixAndRemainPixelDistinct() throws {
        let selectionData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Brand/identity-selection.json")
        )
        let selection = try IdentityExporter.validateApprovedSelection(
            selectionData,
            expectedSHA256: sha256(selectionData)
        )
        let canonicalData = try Data(
            contentsOf: repositoryRoot.appendingPathComponent("Brand/Source/B-right-cursor.svg")
        )
        let canonical = try IdentityExporter.validateCanonicalSVG(
            canonicalData,
            expectedSHA256: sha256(canonicalData)
        )
        let sources = try IdentityExporter.loadApprovedIdentitySources(
            repositoryRoot: repositoryRoot,
            selection: selection,
            canonicalSVG: canonical
        )
        let approved = Dictionary(uniqueKeysWithValues: selection.geometry.pixelFit.map {
            (($0.pointSize * 10) + $0.scale, $0.outputSHA256)
        })

        for pointSize in [16, 18, 20] {
            for scale in [1, 2] {
                var hashes: Set<String> = []
                for kind in IdentityStateKind.allCases {
                    let strokes = try XCTUnwrap(sources.states[kind])
                    let image = try IdentityProductionRasterPipeline.renderState(
                        strokes: strokes,
                        pixelSize: pointSize * scale,
                        supersamplingScale: 16
                    )
                    let expectedComponents = kind == .recording ? 2 : 3
                    XCTAssertEqual(alphaComponentCount(image), expectedComponents, "\(kind) \(pointSize)@\(scale)x")
                    let pngHash = sha256(try PNGEncoder.encode(image))
                    hashes.insert(sha256(Data(image.rgba)))
                    if kind == .recording {
                        XCTAssertEqual(pngHash, approved[(pointSize * 10) + scale])
                    }
                }
                XCTAssertEqual(hashes.count, 4, "state pixels must differ at \(pointSize)@\(scale)x")
            }
        }
    }

    func testProductionCommandLineModesAreStrictAndMutuallyExclusive() throws {
        XCTAssertEqual(
            try IdentityExporterCommandLine.parse(["--output", "dist/review"]),
            .output("dist/review")
        )
        XCTAssertEqual(
            try IdentityExporterCommandLine.parse([
                "--integrate", "--selection", "Brand/identity-selection.json",
                "--lock", "Brand/identity-lock.json",
                "--asset-catalog", "App/Resources/Assets.xcassets",
            ]),
            .integrate(
                selection: "Brand/identity-selection.json",
                lock: "Brand/identity-lock.json",
                assetCatalog: "App/Resources/Assets.xcassets"
            )
        )
        XCTAssertEqual(
            try IdentityExporterCommandLine.parse([
                "--check", "--lock", "Brand/identity-lock.json",
                "--asset-catalog", "App/Resources/Assets.xcassets",
            ]),
            .check(
                lock: "Brand/identity-lock.json",
                assetCatalog: "App/Resources/Assets.xcassets"
            )
        )
        XCTAssertThrowsError(try IdentityExporterCommandLine.parse([
            "--check", "--selection", "Brand/identity-selection.json",
            "--lock", "Brand/identity-lock.json", "--asset-catalog", "App/Resources/Assets.xcassets",
        ]))
        XCTAssertThrowsError(try IdentityExporterCommandLine.parse([
            "--integrate", "--selection", "/tmp/selection.json",
            "--lock", "Brand/identity-lock.json", "--asset-catalog", "App/Resources/Assets.xcassets",
        ]))
        XCTAssertThrowsError(try IdentityExporterCommandLine.parse([
            "--integrate", "--selection", "Brand/../Brand/identity-selection.json",
            "--lock", "Brand/identity-lock.json", "--asset-catalog", "App/Resources/Assets.xcassets",
        ]))
    }
}

private extension IdentityProductionIntegrationTests {
    var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UtterInkProductionIdentityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func copyProductionFixture(to root: URL) throws -> IdentityProductionRequest {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for relative in [
            "Brand/Source", "Brand/states",
            "Packages/UtterInkKit/Sources/UtterInkIdentityExporter",
        ] {
            let source = repositoryRoot.appendingPathComponent(relative, isDirectory: true)
            let destination = root.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
        for relative in [
            "Brand/palettes.json", "Brand/identity-selection.json", "Brand/wordmark-lockup.svg",
        ] {
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: repositoryRoot.appendingPathComponent(relative),
                to: destination
            )
        }
        return IdentityProductionRequest(
            repositoryRoot: root,
            selectionFile: root.appendingPathComponent("Brand/identity-selection.json"),
            lockFile: root.appendingPathComponent("Brand/identity-lock.json"),
            assetCatalog: root.appendingPathComponent("App/Resources/Assets.xcassets", isDirectory: true)
        )
    }

    func recursiveBytes(in root: URL) throws -> [String: Data] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        )
        var result: [String: Data] = [:]
        for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    func writeJSONObject(_ object: Any, to url: URL) throws {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        try data.write(to: url)
    }

    func alphaComponentCount(_ image: RasterImage) -> Int {
        var covered = [Bool](repeating: false, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                covered[y * image.width + x] = image.rgba[(y * image.width + x) * 4 + 3] > 31
            }
        }
        var count = 0
        for start in covered.indices where covered[start] {
            count += 1
            covered[start] = false
            var queue = [start]
            var index = 0
            while index < queue.count {
                let current = queue[index]
                index += 1
                let x = current % image.width
                let y = current / image.width
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < image.width, ny >= 0, ny < image.height else { continue }
                        let next = ny * image.width + nx
                        if covered[next] {
                            covered[next] = false
                            queue.append(next)
                        }
                    }
                }
            }
        }
        return count
    }
}
