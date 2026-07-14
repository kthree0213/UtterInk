import CoreGraphics
import Darwin
import Foundation
import ImageIO

extension IdentityExporter {
    @discardableResult
    static func integrateProductionIdentity(
        request: IdentityProductionRequest,
        configuration: IdentityProductionConfiguration = .production,
        publicationBoundaryHook: (() throws -> Void)? = nil
    ) throws -> IdentityProductionLock {
        let repositoryLock = try ProductionRepositoryLock(
            repositoryRoot: request.repositoryRoot,
            exclusive: true
        )
        defer { repositoryLock.release() }
        let paths = try validateProductionRequest(request)
        let context = try loadProductionContext(
            request: request,
            relativeSelectionPath: paths.selection,
            configuration: configuration
        )
        let catalogBaseline = try productionCatalogBaseline(at: request.assetCatalog)

        let publication = try OutputPublication(destination: request.assetCatalog)
        defer { publication.discardIfNeeded() }
        if productionPathKind(request.assetCatalog) == .directory {
            try copyRealDirectoryContents(
                from: request.assetCatalog,
                to: publication.stagingDirectory
            )
        }
        let generated = try generateProductionCatalog(
            context: context,
            at: publication.stagingDirectory,
            configuration: configuration
        )
        let outputs = try productionOutputRecords(
            in: publication.stagingDirectory,
            metadata: generated
        )
        let lock = IdentityProductionLock(
            approvals: context.selection.approvals,
            assetCatalogPath: paths.assetCatalog,
            brand: "UtterInk",
            exporterAggregateSHA256: context.exporterAggregateSHA256,
            exporterSources: context.exporterSources,
            geometry: context.selection.geometry,
            inputs: context.inputs,
            outputs: outputs,
            palette: context.selection.palette,
            renderer: .init(
                colorSpace: "sRGB",
                cubicSampleCount: context.sources.baseSVG.bowlSampleCount,
                lanczosRadius: Int(LanczosDownsampler.radius),
                linearSupersamplingScale: configuration.linearSupersamplingScale,
                pixelFormat: "RGBA8-premultiplied-last-byte-order-32-big",
                supersamplingSamplesPerPixel: configuration.linearSupersamplingScale
                    * configuration.linearSupersamplingScale,
                toolchainContract: context.toolchainIdentity
            ),
            schemaVersion: 1,
            selection: .init(
                id: "approved-identity-selection",
                path: paths.selection,
                sha256: context.selectionSHA256
            ),
            status: "production-assets-locked",
            trademarkTreatment: context.selection.trademarkTreatment
        )
        let lockData = try encodeProductionLock(lock)
        _ = try validateProductionLock(lockData)

        let stagedLock = try stageProductionLock(lockData, destination: request.lockFile)
        var publishedLock = false
        defer {
            if !publishedLock { try? FileManager.default.removeItem(at: stagedLock) }
        }
        // Stage first, then repeat every mutable-input check immediately before
        // the catalog swap. The advisory repository lock serializes exporter
        // processes; this final comparison also rejects intervening editor,
        // Xcode, or Git changes made during rendering or lock encoding.
        let revalidatedContext = try loadProductionContext(
            request: request,
            relativeSelectionPath: paths.selection,
            configuration: configuration
        )
        let revalidatedCatalogBaseline = try productionCatalogBaseline(at: request.assetCatalog)
        guard productionContextsMatchForPublication(context, revalidatedContext),
              catalogBaseline == revalidatedCatalogBaseline else {
            throw IdentityExporterError.invalidInput(
                "production inputs or asset catalog changed during rendering"
            )
        }
        try publicationBoundaryHook?()
        try publication.commitKeepingPrior()
        do {
            // The atomic swap leaves the exact displaced catalog at the
            // staging path. Comparing that inode tree closes the check/swap
            // race for non-cooperating editor, Xcode, or Git writes: if the
            // swapped-out tree is not our original baseline, restore it before
            // the lock becomes authoritative.
            guard try productionCatalogBaseline(at: publication.stagingDirectory)
                == catalogBaseline else {
                throw IdentityExporterError.invalidInput(
                    "asset catalog changed at the production publication boundary"
                )
            }
        } catch {
            do {
                try publication.rollbackCommit()
            } catch {
                throw IdentityExporterError.invalidInput(
                    "could not validate or restore the publication-boundary asset catalog"
                )
            }
            throw error
        }
        do {
            try publishStagedFile(stagedLock, destination: request.lockFile)
            publishedLock = true
        } catch {
            do {
                try publication.rollbackCommit()
            } catch {
                throw IdentityExporterError.invalidInput(
                    "could not publish identity lock or restore the prior asset catalog"
                )
            }
            throw error
        }
        try publication.finalizeCommit()
        return lock
    }

    static func checkProductionIdentity(
        request: IdentityProductionRequest,
        configuration: IdentityProductionConfiguration = .production
    ) throws {
        let repositoryLock = try ProductionRepositoryLock(
            repositoryRoot: request.repositoryRoot,
            exclusive: false
        )
        defer { repositoryLock.release() }
        let paths = try validateProductionRequest(request, requireSelectionMatch: false)
        let lockData: Data
        let lock: IdentityProductionLock
        do {
            lockData = try SecureFileReader.readRegularFile(
                at: request.lockFile,
                limit: 2 * 1_024 * 1_024,
                displayName: paths.lock
            )
            lock = try validateProductionLock(lockData)
        } catch {
            throw IdentityExporterError.mismatchedFiles([paths.lock])
        }
        guard lock.assetCatalogPath == paths.assetCatalog,
              lock.selection.path == paths.selection,
              lock.renderer.linearSupersamplingScale == configuration.linearSupersamplingScale else {
            throw IdentityExporterError.mismatchedFiles([paths.lock])
        }
        let lockedInputMismatches = productionLockedInputMismatches(lock, root: request.repositoryRoot)
        guard lockedInputMismatches.isEmpty else {
            throw IdentityExporterError.mismatchedFiles(lockedInputMismatches)
        }

        let context: ProductionContext
        do {
            context = try loadProductionContext(
                request: request,
                relativeSelectionPath: lock.selection.path,
                configuration: configuration
            )
        } catch {
            // Every locked regular input was hashed above. Any remaining
            // context failure is a lock/runtime contract mismatch rather than
            // evidence that the approved selection file alone changed.
            throw IdentityExporterError.mismatchedFiles([paths.lock])
        }
        var earlyMismatches: [String] = []
        if context.selectionSHA256 != lock.selection.sha256 {
            earlyMismatches.append(lock.selection.path)
        }
        let expectedRenderer = IdentityProductionLock.Renderer(
            colorSpace: "sRGB",
            cubicSampleCount: context.sources.baseSVG.bowlSampleCount,
            lanczosRadius: Int(LanczosDownsampler.radius),
            linearSupersamplingScale: configuration.linearSupersamplingScale,
            pixelFormat: "RGBA8-premultiplied-last-byte-order-32-big",
            supersamplingSamplesPerPixel: configuration.linearSupersamplingScale
                * configuration.linearSupersamplingScale,
            toolchainContract: context.toolchainIdentity
        )
        if lock.inputs != context.inputs
            || lock.approvals != context.selection.approvals
            || lock.palette != context.selection.palette
            || lock.geometry != context.selection.geometry
            || lock.trademarkTreatment != context.selection.trademarkTreatment
            || lock.renderer != expectedRenderer {
            earlyMismatches.append(paths.lock)
        }
        if lock.exporterSources != context.exporterSources {
            let actualExporter = Dictionary(uniqueKeysWithValues: context.exporterSources.map { ($0.path, $0.sha256) })
            let lockedExporter = Dictionary(uniqueKeysWithValues: lock.exporterSources.map { ($0.path, $0.sha256) })
            for path in Set(actualExporter.keys).union(lockedExporter.keys)
            where actualExporter[path] != lockedExporter[path] {
                earlyMismatches.append(path)
            }
            if Set(actualExporter.keys) == Set(lockedExporter.keys) {
                earlyMismatches.append(paths.lock)
            }
        }
        if context.exporterAggregateSHA256 != lock.exporterAggregateSHA256 {
            earlyMismatches.append(paths.lock)
        }
        guard earlyMismatches.isEmpty else {
            throw IdentityExporterError.mismatchedFiles(Array(Set(earlyMismatches)).sorted())
        }

        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "UtterInkIdentityCheck-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let stagedCatalog = temporaryRoot.appendingPathComponent("Assets.xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedCatalog, withIntermediateDirectories: true)
        guard productionPathKind(request.assetCatalog) == .directory else {
            throw IdentityExporterError.mismatchedFiles([paths.assetCatalog])
        }
        let installedPaths: [String]
        do {
            installedPaths = try relativeRegularFilesForCheck(
                in: request.assetCatalog,
                relativePrefix: "",
                displayRoot: paths.assetCatalog
            )
            try copyRealDirectoryContents(from: request.assetCatalog, to: stagedCatalog)
        } catch let error as IdentityExporterError {
            if case .mismatchedFiles = error { throw error }
            throw IdentityExporterError.mismatchedFiles([paths.assetCatalog])
        } catch {
            throw IdentityExporterError.mismatchedFiles([paths.assetCatalog])
        }
        let generated = try generateProductionCatalog(
            context: context,
            at: stagedCatalog,
            configuration: configuration
        )
        let stagedOutputs = try productionOutputRecords(in: stagedCatalog, metadata: generated)

        let expected = Dictionary(uniqueKeysWithValues: lock.outputs.map { ($0.path, $0) })
        let staged = Dictionary(uniqueKeysWithValues: stagedOutputs.map { ($0.path, $0) })
        let allPaths = Set(expected.keys).union(staged.keys).union(installedPaths)
        var mismatches: [String] = []
        for path in allPaths.sorted() {
            let displayPath = "\(paths.assetCatalog)/\(path)"
            guard let expectedRecord = expected[path], let stagedRecord = staged[path],
                  expectedRecord == stagedRecord, installedPaths.contains(path) else {
                mismatches.append(displayPath)
                continue
            }
            let stagedData = try SecureFileReader.readRegularFile(
                at: stagedCatalog.appendingPathComponent(path),
                limit: 64 * 1_024 * 1_024,
                displayName: displayPath
            )
            let installedData: Data
            do {
                installedData = try SecureFileReader.readRegularFile(
                    at: request.assetCatalog.appendingPathComponent(path),
                    limit: 64 * 1_024 * 1_024,
                    displayName: displayPath
                )
            } catch {
                mismatches.append(displayPath)
                continue
            }
            if stagedData != installedData || sha256(installedData) != expectedRecord.sha256 {
                mismatches.append(displayPath)
            }
        }
        guard mismatches.isEmpty else {
            throw IdentityExporterError.mismatchedFiles(mismatches.sorted())
        }
    }
}

private extension IdentityExporter {
    struct ProductionPaths {
        let selection: String
        let lock: String
        let assetCatalog: String
    }

    struct ProductionContext {
        let selection: ApprovedIdentitySelection
        let selectionSHA256: String
        let sources: ApprovedIdentitySources
        let palette: IdentityPalette
        let inputs: [IdentityProductionLock.FileRecord]
        let exporterSources: [IdentityProductionLock.ExporterFile]
        let exporterAggregateSHA256: String
        let toolchainIdentity: String
    }

    struct GeneratedAssetMetadata {
        let kind: String
        let pixelHeight: Int?
        let pixelWidth: Int?
        let pointSize: Int?
        let scale: Int?
        let templateRenderingIntent: Bool
    }

    struct ProductionCatalogEntry: Equatable {
        enum Kind: Equatable { case directory, file }

        let byteCount: Int?
        let kind: Kind
        let path: String
        let sha256: String?
    }

    enum ProductionCatalogBaseline: Equatable {
        case missing
        case directory([ProductionCatalogEntry])
    }

    static func validateProductionRequest(
        _ request: IdentityProductionRequest,
        requireSelectionMatch: Bool = true
    ) throws -> ProductionPaths {
        let root = request.repositoryRoot.standardizedFileURL
        let selection = try safeRepositoryRelativePath(request.selectionFile, root: root)
        let lock = try safeRepositoryRelativePath(request.lockFile, root: root)
        let catalog = try safeRepositoryRelativePath(request.assetCatalog, root: root)
        if requireSelectionMatch, selection != "Brand/identity-selection.json" {
            throw IdentityExporterError.invalidInput("production selection path changed")
        }
        guard lock == "Brand/identity-lock.json",
              catalog == "App/Resources/Assets.xcassets" else {
            throw IdentityExporterError.invalidInput("production output paths changed")
        }
        return .init(selection: selection, lock: lock, assetCatalog: catalog)
    }

    static func loadProductionContext(
        request: IdentityProductionRequest,
        relativeSelectionPath: String,
        configuration: IdentityProductionConfiguration
    ) throws -> ProductionContext {
        guard configuration.linearSupersamplingScale > 0,
              configuration.linearSupersamplingScale <= IdentityRasterPipeline.linearSupersamplingScale else {
            throw IdentityExporterError.invalidInput("invalid production rendering configuration")
        }
        let selectionData = try SecureFileReader.readRegularFile(
            at: request.repositoryRoot.appendingPathComponent(relativeSelectionPath),
            limit: 128 * 1_024,
            displayName: relativeSelectionPath
        )
        let selectionSHA = sha256(selectionData)
        let selection = try validateApprovedSelection(
            selectionData,
            expectedSHA256: IdentityArtifactLock.approvedSelectionSHA256
        )

        let inputs = IdentityInputPaths(
            sourceDirectory: request.repositoryRoot.appendingPathComponent("Brand/Source", isDirectory: true),
            paletteFile: request.repositoryRoot.appendingPathComponent("Brand/palettes.json")
        )
        let provenance = try validateProvenance(inputs: inputs)
        let canonicalData = try SecureFileReader.readRegularFile(
            at: inputs.sourceDirectory.appendingPathComponent("B-right-cursor.svg"),
            limit: 16 * 1_024,
            displayName: "Brand/Source/B-right-cursor.svg"
        )
        let canonical = try validateCanonicalSVG(
            canonicalData,
            expectedSHA256: IdentityArtifactLock.rightCursorSHA256
        )
        let approvedSources = try loadApprovedIdentitySources(
            repositoryRoot: request.repositoryRoot,
            selection: selection,
            canonicalSVG: canonical
        )

        let paletteData = try SecureFileReader.readRegularFile(
            at: inputs.paletteFile,
            limit: 16 * 1_024,
            displayName: "Brand/palettes.json"
        )
        guard sha256(paletteData) == selection.palette.sourceSHA256 else {
            throw IdentityExporterError.invalidInput("approved palette source changed")
        }
        let palette = IdentityPalette(
            name: selection.palette.id,
            background: try IdentityColor(hex: selection.palette.background),
            mark: try IdentityColor(hex: selection.palette.mark)
        )

        var inputRecords = [IdentityProductionLock.FileRecord(
            id: "approved-identity-selection",
            path: relativeSelectionPath,
            sha256: selectionSHA
        ), .init(
            id: "palettes",
            path: "Brand/palettes.json",
            sha256: sha256(paletteData)
        )]
        let provenanceData = try SecureFileReader.readRegularFile(
            at: inputs.provenanceFile,
            limit: 128 * 1_024,
            displayName: "Brand/Source/provenance.json"
        )
        inputRecords.append(.init(
            id: "canonical-provenance",
            path: "Brand/Source/provenance.json",
            sha256: sha256(provenanceData)
        ))
        inputRecords.append(contentsOf: provenance.artifacts.map {
            .init(id: $0.id, path: $0.repositoryPath, sha256: $0.sha256)
        })
        inputRecords.append(contentsOf: selection.sourceFamily.map {
            .init(id: $0.id, path: $0.path, sha256: $0.sha256)
        })
        inputRecords.sort { $0.path < $1.path }

        let exporterIdentity = try productionExporterSourceIdentity(root: request.repositoryRoot)
        let toolchainIdentity = try resolvedToolchainIdentity(configuration: configuration)
        return .init(
            selection: selection,
            selectionSHA256: selectionSHA,
            sources: approvedSources,
            palette: palette,
            inputs: inputRecords,
            exporterSources: exporterIdentity.files,
            exporterAggregateSHA256: exporterIdentity.aggregate,
            toolchainIdentity: toolchainIdentity
        )
    }

    static func productionContextsMatchForPublication(
        _ first: ProductionContext,
        _ second: ProductionContext
    ) -> Bool {
        first.selection == second.selection
            && first.selectionSHA256 == second.selectionSHA256
            && first.palette == second.palette
            && first.inputs == second.inputs
            && first.exporterSources == second.exporterSources
            && first.exporterAggregateSHA256 == second.exporterAggregateSHA256
            && first.toolchainIdentity == second.toolchainIdentity
    }

    static func productionLockedInputMismatches(
        _ lock: IdentityProductionLock,
        root: URL
    ) -> [String] {
        let optionalInputs: Set<String> = [
            "dist/identity-input-review/menu-bar-comparison.png",
        ]
        var mismatches: [String] = []
        for record in lock.inputs {
            let url = root.appendingPathComponent(record.path)
            if optionalInputs.contains(record.path), productionPathKind(url) == .missing {
                continue
            }
            do {
                let data = try SecureFileReader.readRegularFile(
                    at: url,
                    limit: 64 * 1_024 * 1_024,
                    displayName: record.path
                )
                if sha256(data) != record.sha256 { mismatches.append(record.path) }
            } catch {
                mismatches.append(record.path)
            }
        }
        for record in lock.exporterSources {
            do {
                let data = try SecureFileReader.readRegularFile(
                    at: root.appendingPathComponent(record.path),
                    limit: 512 * 1_024,
                    displayName: record.path
                )
                if sha256(data) != record.sha256 { mismatches.append(record.path) }
            } catch {
                mismatches.append(record.path)
            }
        }
        return Array(Set(mismatches)).sorted()
    }

    static func productionCatalogBaseline(at catalog: URL) throws -> ProductionCatalogBaseline {
        switch productionPathKind(catalog) {
        case .missing:
            return .missing
        case .directory:
            return .directory(try productionCatalogEntries(in: catalog, prefix: ""))
        case .file, .other:
            throw IdentityExporterError.invalidInput("asset catalog must be a real directory")
        }
    }

    static func productionCatalogEntries(
        in directory: URL,
        prefix: String
    ) throws -> [ProductionCatalogEntry] {
        guard productionPathKind(directory) == .directory else {
            throw IdentityExporterError.invalidInput("asset catalog contains unsafe entries")
        }
        var entries: [ProductionCatalogEntry] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
            let child = directory.appendingPathComponent(name)
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            switch productionPathKind(child) {
            case .directory:
                entries.append(.init(byteCount: nil, kind: .directory, path: path, sha256: nil))
                entries.append(contentsOf: try productionCatalogEntries(in: child, prefix: path))
            case .file:
                let data = try SecureFileReader.readRegularFile(
                    at: child,
                    limit: 64 * 1_024 * 1_024,
                    displayName: path
                )
                entries.append(.init(
                    byteCount: data.count,
                    kind: .file,
                    path: path,
                    sha256: sha256(data)
                ))
            case .missing, .other:
                throw IdentityExporterError.invalidInput(
                    "asset catalog contains symlinks or special files"
                )
            }
        }
        return entries
    }

    static func generateProductionCatalog(
        context: ProductionContext,
        at catalog: URL,
        configuration: IdentityProductionConfiguration
    ) throws -> [String: GeneratedAssetMetadata] {
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: true)
        let ownedRoots = [
            "AppIcon.appiconset", "MenuBarIcon16.imageset", "MenuBarIcon.imageset",
            "MenuBarIcon20.imageset", "BrandMark.imageset", "StatusRecording.imageset",
            "StatusProcessing.imageset", "StatusSuccess.imageset", "StatusFailure.imageset",
        ]
        for root in ownedRoots {
            let url = catalog.appendingPathComponent(root, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var metadata: [String: GeneratedAssetMetadata] = [:]
        let rootContents = catalog.appendingPathComponent("Contents.json")
        try writeDeterministicJSONObject(
            ["info": ["author": "xcode", "version": 1]],
            to: rootContents
        )
        metadata["Contents.json"] = .init(
            kind: "asset-catalog-contents", pixelHeight: nil, pixelWidth: nil,
            pointSize: nil, scale: nil, templateRenderingIntent: false
        )

        let master = try IdentityRasterPipeline.renderAppIconMasterMask(
            svg: context.sources.baseSVG,
            supersamplingScale: configuration.linearSupersamplingScale
        )
        let appContracts: [(Int, Int, Int, String)] = [
            (16, 1, 16, "appicon-16x16@1x.png"),
            (16, 2, 32, "appicon-16x16@2x.png"),
            (32, 1, 32, "appicon-32x32@1x.png"),
            (32, 2, 64, "appicon-32x32@2x.png"),
            (128, 1, 128, "appicon-128x128@1x.png"),
            (128, 2, 256, "appicon-128x128@2x.png"),
            (256, 1, 256, "appicon-256x256@1x.png"),
            (256, 2, 512, "appicon-256x256@2x.png"),
            (512, 1, 512, "appicon-512x512@1x.png"),
            (512, 2, 1_024, "appicon-512x512@2x.png"),
        ]
        var appMasks: [Int: RasterImage] = [1_024: master]
        for size in Set(appContracts.map { $0.2 }).sorted() where size != 1_024 {
            appMasks[size] = try IdentityRasterPipeline.resizedMask(master, pixelSize: size)
        }
        let appDirectory = catalog.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        var appImages: [[String: Any]] = []
        for contract in appContracts {
            guard let mask = appMasks[contract.2] else {
                throw IdentityExporterError.invalidInput("missing production App Icon mask")
            }
            let image = try IdentityRasterPipeline.composite(mask: mask, palette: context.palette)
            let relative = "AppIcon.appiconset/\(contract.3)"
            try writeProductionPNG(image, to: catalog.appendingPathComponent(relative))
            metadata[relative] = .init(
                kind: "app-icon", pixelHeight: contract.2, pixelWidth: contract.2,
                pointSize: contract.0, scale: contract.1, templateRenderingIntent: false
            )
            appImages.append([
                "filename": contract.3, "idiom": "mac", "scale": "\(contract.1)x",
                "size": "\(contract.0)x\(contract.0)",
            ])
        }
        try writeDeterministicJSONObject(
            ["images": appImages, "info": ["author": "xcode", "version": 1]],
            to: appDirectory.appendingPathComponent("Contents.json")
        )
        metadata["AppIcon.appiconset/Contents.json"] = .init(
            kind: "asset-contents", pixelHeight: nil, pixelWidth: nil,
            pointSize: nil, scale: nil, templateRenderingIntent: false
        )

        let menuSets: [(Int, String)] = [
            (16, "MenuBarIcon16"), (18, "MenuBarIcon"), (20, "MenuBarIcon20"),
        ]
        let approvedMenuHashes = Dictionary(uniqueKeysWithValues:
            context.selection.geometry.pixelFit.map { (($0.pointSize * 10) + $0.scale, $0.outputSHA256) }
        )
        for (pointSize, setName) in menuSets {
            let directory = catalog.appendingPathComponent("\(setName).imageset", isDirectory: true)
            var images: [[String: Any]] = []
            for scale in [1, 2] {
                let image = try IdentityRasterPipeline.renderMenu(
                    svg: context.sources.baseSVG,
                    pixelSize: pointSize * scale,
                    supersamplingScale: configuration.linearSupersamplingScale
                )
                let filename = "\(setName)@\(scale)x.png"
                let relative = "\(setName).imageset/\(filename)"
                let data = try writeProductionPNG(image, to: catalog.appendingPathComponent(relative))
                if configuration == .production,
                   sha256(data) != approvedMenuHashes[(pointSize * 10) + scale] {
                    throw IdentityExporterError.invalidInput("production menu pixels no longer match approval")
                }
                metadata[relative] = .init(
                    kind: "menu-template", pixelHeight: image.height, pixelWidth: image.width,
                    pointSize: pointSize, scale: scale, templateRenderingIntent: true
                )
                images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
            }
            try writeTemplateContents(images: images, to: directory.appendingPathComponent("Contents.json"))
            metadata["\(setName).imageset/Contents.json"] = .init(
                kind: "asset-contents", pixelHeight: nil, pixelWidth: nil,
                pointSize: nil, scale: nil, templateRenderingIntent: true
            )
        }

        let statusSets: [(IdentityStateKind, String)] = [
            (.recording, "StatusRecording"), (.processing, "StatusProcessing"),
            (.success, "StatusSuccess"), (.failure, "StatusFailure"),
        ]
        for (kind, setName) in statusSets {
            guard let strokes = context.sources.states[kind] else {
                throw IdentityExporterError.invalidInput("approved state geometry is missing")
            }
            let directory = catalog.appendingPathComponent("\(setName).imageset", isDirectory: true)
            var images: [[String: Any]] = []
            for scale in [1, 2] {
                let image = try IdentityProductionRasterPipeline.renderState(
                    strokes: strokes,
                    pixelSize: 18 * scale,
                    supersamplingScale: configuration.linearSupersamplingScale
                )
                let filename = "\(setName)@\(scale)x.png"
                let relative = "\(setName).imageset/\(filename)"
                try writeProductionPNG(image, to: catalog.appendingPathComponent(relative))
                metadata[relative] = .init(
                    kind: "status-template", pixelHeight: image.height, pixelWidth: image.width,
                    pointSize: 18, scale: scale, templateRenderingIntent: true
                )
                images.append(["filename": filename, "idiom": "mac", "scale": "\(scale)x"])
            }
            try writeTemplateContents(images: images, to: directory.appendingPathComponent("Contents.json"))
            metadata["\(setName).imageset/Contents.json"] = .init(
                kind: "asset-contents", pixelHeight: nil, pixelWidth: nil,
                pointSize: nil, scale: nil, templateRenderingIntent: true
            )
        }

        guard let brandStrokes = context.sources.states[.recording] else {
            throw IdentityExporterError.invalidInput("brand mark geometry is missing")
        }
        let brandDirectory = catalog.appendingPathComponent("BrandMark.imageset", isDirectory: true)
        var brandImages: [[String: Any]] = []
        for scale in [1, 2] {
            let size = 128 * scale
            let image = try IdentityProductionRasterPipeline.renderState(
                strokes: brandStrokes,
                pixelSize: size,
                supersamplingScale: configuration.linearSupersamplingScale
            )
            let filename = "BrandMark@\(scale)x.png"
            let relative = "BrandMark.imageset/\(filename)"
            try writeProductionPNG(image, to: catalog.appendingPathComponent(relative))
            metadata[relative] = .init(
                kind: "brand-template", pixelHeight: size, pixelWidth: size,
                pointSize: 128, scale: scale, templateRenderingIntent: true
            )
            brandImages.append(["filename": filename, "idiom": "universal", "scale": "\(scale)x"])
        }
        try writeTemplateContents(images: brandImages, to: brandDirectory.appendingPathComponent("Contents.json"))
        metadata["BrandMark.imageset/Contents.json"] = .init(
            kind: "asset-contents", pixelHeight: nil, pixelWidth: nil,
            pointSize: nil, scale: nil, templateRenderingIntent: true
        )
        return metadata
    }

    static func productionOutputRecords(
        in catalog: URL,
        metadata: [String: GeneratedAssetMetadata]
    ) throws -> [IdentityProductionLock.Output] {
        try relativeRegularFilesStrict(in: catalog).map { path in
            let data = try SecureFileReader.readRegularFile(
                at: catalog.appendingPathComponent(path),
                limit: 64 * 1_024 * 1_024,
                displayName: path
            )
            let info = metadata[path] ?? .init(
                kind: "preserved-catalog-file", pixelHeight: nil, pixelWidth: nil,
                pointSize: nil, scale: nil, templateRenderingIntent: false
            )
            return .init(
                byteCount: data.count,
                kind: info.kind,
                path: path,
                pixelHeight: info.pixelHeight,
                pixelWidth: info.pixelWidth,
                pointSize: info.pointSize,
                scale: info.scale,
                sha256: sha256(data),
                templateRenderingIntent: info.templateRenderingIntent
            )
        }.sorted { $0.path < $1.path }
    }

    static func writeTemplateContents(images: [[String: Any]], to url: URL) throws {
        try writeDeterministicJSONObject([
            "images": images,
            "info": ["author": "xcode", "version": 1],
            "properties": ["template-rendering-intent": "template"],
        ], to: url)
    }

    @discardableResult
    static func writeProductionPNG(_ image: RasterImage, to url: URL) throws -> Data {
        let data = try PNGEncoder.encode(image)
        try data.write(to: url, options: .atomic)
        return data
    }

    static func writeDeterministicJSONObject(_ object: Any, to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw IdentityExporterError.invalidInput("asset JSON is invalid")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    static func encodeProductionLock(_ lock: IdentityProductionLock) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(lock)
        data.append(0x0a)
        return data
    }

    static func validateProductionLock(_ data: Data) throws -> IdentityProductionLock {
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 else {
            throw IdentityExporterError.invalidInput("identity lock size is outside its boundary")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw IdentityExporterError.invalidInput("identity lock JSON is invalid")
        }
        guard let root = object as? [String: Any], Set(root.keys) == Set([
            "approvals", "assetCatalogPath", "brand", "exporterAggregateSHA256",
            "exporterSources", "geometry", "inputs", "outputs", "palette", "renderer",
            "schemaVersion", "selection", "status", "trademarkTreatment",
        ]) else {
            throw IdentityExporterError.invalidInput("identity lock keys changed")
        }
        try validateProductionLockShape(root)
        let lock: IdentityProductionLock
        do {
            lock = try JSONDecoder().decode(IdentityProductionLock.self, from: data)
        } catch {
            throw IdentityExporterError.invalidInput("identity lock JSON is invalid")
        }
        guard lock.schemaVersion == 1,
              lock.brand == "UtterInk",
              lock.status == "production-assets-locked",
              lock.selection.id == "approved-identity-selection",
              lock.selection.path == "Brand/identity-selection.json",
              lock.selection.sha256 == IdentityArtifactLock.approvedSelectionSHA256,
              lock.assetCatalogPath == "App/Resources/Assets.xcassets",
              lock.exporterAggregateSHA256.isLowercaseSHA256,
              lock.approvals.count == 2,
              lock.outputs == lock.outputs.sorted(by: { $0.path < $1.path }),
              Set(lock.outputs.map(\.path)).count == lock.outputs.count,
              lock.exporterSources == lock.exporterSources.sorted(by: { $0.path < $1.path }),
              Set(lock.exporterSources.map(\.path)).count == lock.exporterSources.count,
              lock.inputs == lock.inputs.sorted(by: { $0.path < $1.path }),
              Set(lock.inputs.map(\.path)).count == lock.inputs.count else {
            throw IdentityExporterError.invalidInput("identity lock contract changed")
        }
        for input in lock.inputs {
            try validateSafeRelativePath(input.path)
            guard !input.id.isEmpty, input.sha256.isLowercaseSHA256 else {
                throw IdentityExporterError.invalidInput("identity lock input record is invalid")
            }
        }
        for source in lock.exporterSources {
            try validateSafeRelativePath(source.path)
            guard source.path.hasPrefix("Packages/UtterInkKit/Sources/UtterInkIdentityExporter/"),
                  source.sha256.isLowercaseSHA256 else {
                throw IdentityExporterError.invalidInput("identity lock exporter record is invalid")
            }
        }
        for output in lock.outputs {
            try validateSafeRelativePath(output.path)
            guard output.byteCount > 0, output.sha256.isLowercaseSHA256 else {
                throw IdentityExporterError.invalidInput("identity lock output record is invalid")
            }
        }
        return lock
    }

    static func validateProductionLockShape(_ root: [String: Any]) throws {
        guard let approvals = root["approvals"] as? [[String: Any]],
              approvals.allSatisfy({ Set($0.keys) == [
                  "evidence", "reviewer", "scope", "status", "timestamp",
              ] }),
              let exporterSources = root["exporterSources"] as? [[String: Any]],
              exporterSources.allSatisfy({ Set($0.keys) == ["path", "sha256"] }),
              let inputs = root["inputs"] as? [[String: Any]],
              inputs.allSatisfy({ Set($0.keys) == ["id", "path", "sha256"] }),
              let outputs = root["outputs"] as? [[String: Any]],
              outputs.allSatisfy({ output in
                  let keys = Set(output.keys)
                  let required: Set<String> = [
                      "byteCount", "kind", "path", "sha256", "templateRenderingIntent",
                  ]
                  let allowed = required.union([
                      "pixelHeight", "pixelWidth", "pointSize", "scale",
                  ])
                  return keys.isSuperset(of: required) && keys.isSubset(of: allowed)
              }),
              let selection = root["selection"] as? [String: Any],
              Set(selection.keys) == ["id", "path", "sha256"],
              let palette = root["palette"] as? [String: Any],
              Set(palette.keys) == ["background", "id", "mark", "sourceSHA256"],
              let renderer = root["renderer"] as? [String: Any],
              Set(renderer.keys) == [
                  "colorSpace", "cubicSampleCount", "lanczosRadius",
                  "linearSupersamplingScale", "pixelFormat", "supersamplingSamplesPerPixel",
                  "toolchainContract",
              ],
              let geometry = root["geometry"] as? [String: Any],
              Set(geometry.keys) == [
                  "alphaConnectivity", "alphaThresholdExclusive", "canonicalCursorPath",
                  "cursorTranslationY", "id", "pixelFit", "resolvedCursorPath",
                  "visibleInkGapSVGUnits",
              ],
              let pixelFit = geometry["pixelFit"] as? [[String: Any]],
              pixelFit.allSatisfy({ Set($0.keys) == [
                  "componentCount", "cursorHeight", "cursorWidth", "outputSHA256",
                  "pixelSize", "pointSize", "scale",
              ] }) else {
            throw IdentityExporterError.invalidInput("identity lock nested keys changed")
        }
    }

    static func productionExporterSourceIdentity(
        root: URL
    ) throws -> (files: [IdentityProductionLock.ExporterFile], aggregate: String) {
        let sourceRoot = root.appendingPathComponent(
            "Packages/UtterInkKit/Sources/UtterInkIdentityExporter",
            isDirectory: true
        )
        let paths = try relativeRegularFilesStrict(in: sourceRoot).filter { $0.hasSuffix(".swift") }
        guard !paths.isEmpty else {
            throw IdentityExporterError.invalidInput("exporter source identity is unavailable")
        }
        var aggregate = Data()
        var files: [IdentityProductionLock.ExporterFile] = []
        for relative in paths.sorted() {
            let data = try SecureFileReader.readRegularFile(
                at: sourceRoot.appendingPathComponent(relative),
                limit: 512 * 1_024,
                displayName: relative
            )
            let repositoryPath = "Packages/UtterInkKit/Sources/UtterInkIdentityExporter/\(relative)"
            files.append(.init(path: repositoryPath, sha256: sha256(data)))
            aggregate.append(Data(repositoryPath.utf8))
            aggregate.append(0)
            aggregate.append(data)
            aggregate.append(0)
        }
        return (files.sorted { $0.path < $1.path }, sha256(aggregate))
    }

    static func resolvedToolchainIdentity(
        configuration: IdentityProductionConfiguration
    ) throws -> String {
        if let injected = configuration.toolchainIdentity {
            guard !injected.isEmpty, !injected.contains("\n"), !injected.contains("\r") else {
                throw IdentityExporterError.invalidInput("invalid injected toolchain identity")
            }
            return injected
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw IdentityExporterError.invalidInput("could not read Swift toolchain identity")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let raw = String(data: data, encoding: .utf8) else {
            throw IdentityExporterError.invalidInput("could not read Swift toolchain identity")
        }
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hasSupportedPrefix = normalized.hasPrefix("Apple Swift version ")
            || normalized.hasPrefix("swift-driver version: ")
        guard hasSupportedPrefix,
              normalized.contains(" Apple Swift version ")
                || normalized.hasPrefix("Apple Swift version "),
              normalized.contains(" Target: ") else {
            throw IdentityExporterError.invalidInput("unexpected Swift toolchain identity")
        }
        let runtime = ProcessInfo.processInfo.operatingSystemVersionString
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !runtime.isEmpty else {
            throw IdentityExporterError.invalidInput("could not read macOS rendering runtime identity")
        }
        return "\(normalized) | CoreGraphics runtime: \(runtime)"
    }

    static func relativeRegularFilesStrict(in root: URL) throws -> [String] {
        guard productionPathKind(root) == .directory else {
            throw IdentityExporterError.invalidInput("identity directory is missing")
        }
        let enumerator = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        var result: [String] = []
        for child in enumerator.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            switch productionPathKind(child) {
            case .directory:
                for nested in try relativeRegularFilesStrict(in: child) {
                    result.append("\(child.lastPathComponent)/\(nested)")
                }
            case .file:
                result.append(child.lastPathComponent)
            case .missing, .other:
                throw IdentityExporterError.invalidInput("identity directory contains unsafe entries")
            }
        }
        return result.sorted()
    }

    static func relativeRegularFilesForCheck(
        in root: URL,
        relativePrefix: String,
        displayRoot: String
    ) throws -> [String] {
        guard productionPathKind(root) == .directory else {
            let displayPath = relativePrefix.isEmpty
                ? displayRoot
                : "\(displayRoot)/\(relativePrefix)"
            throw IdentityExporterError.mismatchedFiles([displayPath])
        }
        var result: [String] = []
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relativePath = relativePrefix.isEmpty
                ? child.lastPathComponent
                : "\(relativePrefix)/\(child.lastPathComponent)"
            let displayPath = "\(displayRoot)/\(relativePath)"
            switch productionPathKind(child) {
            case .directory:
                result.append(contentsOf: try relativeRegularFilesForCheck(
                    in: child,
                    relativePrefix: relativePath,
                    displayRoot: displayRoot
                ))
            case .file:
                result.append(relativePath)
            case .missing, .other:
                throw IdentityExporterError.mismatchedFiles([displayPath])
            }
        }
        return result.sorted()
    }

    static func copyRealDirectoryContents(from source: URL, to destination: URL) throws {
        guard productionPathKind(source) == .directory,
              productionPathKind(destination) == .directory else {
            throw IdentityExporterError.invalidInput("catalog copy requires real directories")
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
            let input = source.appendingPathComponent(name)
            let output = destination.appendingPathComponent(name)
            switch productionPathKind(input) {
            case .directory:
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                try copyRealDirectoryContents(from: input, to: output)
            case .file:
                let data = try SecureFileReader.readRegularFile(
                    at: input,
                    limit: 64 * 1_024 * 1_024,
                    displayName: name
                )
                try data.write(to: output, options: .atomic)
            case .missing, .other:
                throw IdentityExporterError.invalidInput("catalog contains symlinks or special files")
            }
        }
    }

    static func stageProductionLock(_ data: Data, destination: URL) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        guard productionPathKind(parent) == .directory else {
            throw IdentityExporterError.invalidInput("identity lock parent must be a real directory")
        }
        switch productionPathKind(destination) {
        case .missing, .file:
            break
        case .directory, .other:
            throw IdentityExporterError.invalidInput("identity lock path must be a regular file")
        }
        let staged = parent.appendingPathComponent(".identity-lock.utterink-staging-\(UUID().uuidString)")
        try data.write(to: staged, options: .withoutOverwriting)
        return staged
    }

    static func publishStagedFile(_ staged: URL, destination: URL) throws {
        switch productionPathKind(destination) {
        case .missing, .file:
            guard Darwin.rename(staged.path, destination.path) == 0 else {
                throw IdentityExporterError.invalidInput("could not publish identity lock")
            }
        case .directory, .other:
            throw IdentityExporterError.invalidInput("identity lock path changed during publication")
        }
    }

    static func safeRepositoryRelativePath(_ url: URL, root: URL) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard targetComponents.starts(with: rootComponents), targetComponents.count > rootComponents.count else {
            throw IdentityExporterError.invalidInput("production path escapes repository root")
        }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        try validateSafeRelativePath(relative)
        return relative
    }

    static func validateSafeRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw IdentityExporterError.invalidInput("unsafe relative identity path")
        }
    }

    enum ProductionPathKind { case missing, file, directory, other }

    static func productionPathKind(_ url: URL) -> ProductionPathKind {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        if result != 0 { return errno == ENOENT ? .missing : .other }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        default: return .other
        }
    }
}

private extension String {
    var isLowercaseSHA256: Bool {
        count == 64 && allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

private final class ProductionRepositoryLock {
    private var descriptor: Int32

    init(repositoryRoot: URL, exclusive: Bool) throws {
        descriptor = Darwin.open(repositoryRoot.standardizedFileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw IdentityExporterError.invalidInput("could not open repository for identity lock")
        }

        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            Darwin.close(descriptor)
            descriptor = -1
            throw IdentityExporterError.invalidInput("identity repository root must be a real directory")
        }

        let operation = exclusive ? LOCK_EX : LOCK_SH
        guard utterInkFlock(descriptor, operation) == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw IdentityExporterError.invalidInput("could not lock repository for identity operation")
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = utterInkFlock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

// Darwin exposes both `struct flock` and the BSD `flock(2)` symbol. Swift's
// importer resolves the qualified spelling to the struct, so bind the libc
// function under an unambiguous private name.
@_silgen_name("flock")
private func utterInkFlock(_ descriptor: Int32, _ operation: Int32) -> Int32
