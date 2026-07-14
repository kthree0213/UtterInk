import Foundation

struct IdentityExportManifest: Codable, Equatable, Sendable {
    struct CanonicalInput: Codable, Equatable, Sendable {
        let id: String
        let sha256: String
    }

    struct Renderer: Codable, Equatable, Sendable {
        let colorSpace: String
        let cubicSampleCount: Int
        let lanczosRadius: Int
        let linearSupersamplingScale: Int
        let pixelFormat: String
        let supersamplingSamplesPerPixel: Int
    }

    struct Output: Codable, Equatable, Sendable {
        let kind: String
        let palette: String?
        let path: String
        let pixelHeight: Int
        let pixelWidth: Int
        let scale: Int?
        let sha256: String
    }

    let brand: String
    let canonicalInputs: [CanonicalInput]
    let outputs: [Output]
    let renderer: Renderer
    let reviewStatus: String
    let schemaVersion: Int
}

extension IdentityExporter {
    @discardableResult
    static func export(
        inputs: IdentityInputPaths,
        outputDirectory: URL
    ) throws -> IdentityExportManifest {
        let provenance = try validateProvenance(inputs: inputs)
        let palettes = try loadPalettes(at: inputs.paletteFile)
        let svgURL = inputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg")
        let svgData = try SecureFileReader.readRegularFile(
            at: svgURL,
            limit: 16 * 1_024,
            displayName: "B-right-cursor.svg"
        )
        let expectedSVGHash = provenance.sha256(for: "right-cursor-vector")
            ?? IdentityArtifactLock.rightCursorSHA256
        let svg = try validateCanonicalSVG(svgData, expectedSHA256: expectedSVGHash)

        let publication = try OutputPublication(destination: outputDirectory)
        defer { publication.discardIfNeeded() }
        let workingDirectory = publication.stagingDirectory
        var outputs: [IdentityExportManifest.Output] = []
        var menuReviewAssets: [IdentityReviewAsset] = []

        for menu in menuContracts {
            let image = try IdentityRasterPipeline.renderMenu(svg: svg, pixelSize: menu.pixelSize)
            try writePNG(
                image,
                name: menu.name,
                kind: "menu-template",
                palette: nil,
                scale: menu.scale,
                outputDirectory: workingDirectory,
                outputs: &outputs
            )
            menuReviewAssets.append(.init(label: menu.label, image: image))
        }

        let masterMask = try IdentityRasterPipeline.renderAppIconMasterMask(svg: svg)
        let requiredPixelSizes = Set(appIconContracts.map(\.pixelSize))
        var masksBySize: [Int: RasterImage] = [1_024: masterMask]
        for pixelSize in requiredPixelSizes.sorted() where pixelSize != 1_024 {
            masksBySize[pixelSize] = try IdentityRasterPipeline.resizedMask(
                masterMask,
                pixelSize: pixelSize
            )
        }

        var appIconReviewAssets: [IdentityReviewAsset] = []
        for palette in palettes {
            for slot in appIconContracts {
                guard let mask = masksBySize[slot.pixelSize] else {
                    throw IdentityExporterError.invalidInput("missing deterministic App Icon mask")
                }
                let image = try IdentityRasterPipeline.composite(mask: mask, palette: palette)
                let name = slot.fileName(palette.name)
                try writePNG(
                    image,
                    name: name,
                    kind: "app-icon",
                    palette: palette.name,
                    scale: slot.scale,
                    outputDirectory: workingDirectory,
                    outputs: &outputs
                )
            }

            guard let previewMask = masksBySize[256] else {
                throw IdentityExporterError.invalidInput("missing App Icon review mask")
            }
            appIconReviewAssets.append(.init(
                label: palette.name.uppercased(),
                image: try IdentityRasterPipeline.composite(mask: previewMask, palette: palette)
            ))
        }

        let reviewSheet = try IdentityReviewSheetRenderer.render(
            menuAssets: menuReviewAssets,
            appIconAssets: appIconReviewAssets
        )
        try writePNG(
            reviewSheet,
            name: "identity-review.png",
            kind: "local-review-sheet",
            palette: nil,
            scale: nil,
            outputDirectory: workingDirectory,
            outputs: &outputs
        )

        let manifest = IdentityExportManifest(
            brand: "UtterInk",
            canonicalInputs: provenance.artifacts.map {
                .init(id: $0.id, sha256: $0.sha256)
            },
            outputs: outputs,
            renderer: .init(
                colorSpace: "sRGB",
                cubicSampleCount: svg.bowlSampleCount,
                lanczosRadius: Int(LanczosDownsampler.radius),
                linearSupersamplingScale: IdentityRasterPipeline.linearSupersamplingScale,
                pixelFormat: "RGBA8-premultiplied-last-byte-order-32-big",
                supersamplingSamplesPerPixel: IdentityRasterPipeline.supersamplingSamplesPerPixel
            ),
            reviewStatus: "task-1-candidate-not-final",
            schemaVersion: 1
        )
        try writeManifest(manifest, to: workingDirectory.appendingPathComponent("identity-metadata.json"))
        try publication.commit()
        return manifest
    }

    private static let menuContracts: [(name: String, label: String, pixelSize: Int, scale: Int)] = [
        ("menu-16@1x.png", "16@1X", 16, 1),
        ("menu-16@2x.png", "16@2X", 32, 2),
        ("menu-18@1x.png", "18@1X", 18, 1),
        ("menu-18@2x.png", "18@2X", 36, 2),
        ("menu-20@1x.png", "20@1X", 20, 1),
        ("menu-20@2x.png", "20@2X", 40, 2),
    ]

    private struct AppIconContract {
        let pointSize: Int
        let scale: Int
        let pixelSize: Int
        let usesRequired1024Name: Bool

        func fileName(_ palette: String) -> String {
            if usesRequired1024Name {
                return "appicon-\(palette)-1024.png"
            }
            return "appicon-\(palette)-\(pointSize)x\(pointSize)@\(scale)x.png"
        }
    }

    private static let appIconContracts: [AppIconContract] = [
        .init(pointSize: 16, scale: 1, pixelSize: 16, usesRequired1024Name: false),
        .init(pointSize: 16, scale: 2, pixelSize: 32, usesRequired1024Name: false),
        .init(pointSize: 32, scale: 1, pixelSize: 32, usesRequired1024Name: false),
        .init(pointSize: 32, scale: 2, pixelSize: 64, usesRequired1024Name: false),
        .init(pointSize: 128, scale: 1, pixelSize: 128, usesRequired1024Name: false),
        .init(pointSize: 128, scale: 2, pixelSize: 256, usesRequired1024Name: false),
        .init(pointSize: 256, scale: 1, pixelSize: 256, usesRequired1024Name: false),
        .init(pointSize: 256, scale: 2, pixelSize: 512, usesRequired1024Name: false),
        .init(pointSize: 512, scale: 1, pixelSize: 512, usesRequired1024Name: false),
        .init(pointSize: 512, scale: 2, pixelSize: 1_024, usesRequired1024Name: true),
    ]

    private static func loadPalettes(at url: URL) throws -> [IdentityPalette] {
        let data = try SecureFileReader.readRegularFile(
            at: url,
            limit: 16 * 1_024,
            displayName: "palettes.json"
        )
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw IdentityExporterError.invalidInput("palette JSON is malformed")
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == Set(["night-ink", "warm-paper", "slate"]) else {
            throw IdentityExporterError.invalidInput("palette names changed")
        }

        let expected: [(String, String, String)] = [
            ("night-ink", "#171821", "#F3F0E8"),
            ("warm-paper", "#ECE6DA", "#1D1E25"),
            ("slate", "#24303A", "#EEF1F2"),
        ]
        return try expected.map { name, expectedBackground, expectedMark in
            guard let record = root[name] as? [String: Any],
                  Set(record.keys) == Set(["background", "mark"]),
                  let background = record["background"] as? String,
                  let mark = record["mark"] as? String,
                  background == expectedBackground,
                  mark == expectedMark else {
                throw IdentityExporterError.invalidInput("palette values changed")
            }
            return IdentityPalette(
                name: name,
                background: try IdentityColor(hex: background),
                mark: try IdentityColor(hex: mark)
            )
        }
    }

    private static func writePNG(
        _ image: RasterImage,
        name: String,
        kind: String,
        palette: String?,
        scale: Int?,
        outputDirectory: URL,
        outputs: inout [IdentityExportManifest.Output]
    ) throws {
        let data = try PNGEncoder.encode(image)
        try data.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
        outputs.append(.init(
            kind: kind,
            palette: palette,
            path: name,
            pixelHeight: image.height,
            pixelWidth: image.width,
            scale: scale,
            sha256: sha256(data)
        ))
    }

    private static func writeManifest(_ manifest: IdentityExportManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

}
