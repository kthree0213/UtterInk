import Foundation

struct IdentityProductionRequest: Sendable {
    let repositoryRoot: URL
    let selectionFile: URL
    let lockFile: URL
    let assetCatalog: URL
}

struct IdentityProductionConfiguration: Equatable, Sendable {
    let linearSupersamplingScale: Int
    let toolchainIdentity: String?

    static let production = IdentityProductionConfiguration(
        linearSupersamplingScale: IdentityRasterPipeline.linearSupersamplingScale,
        toolchainIdentity: nil
    )
    static let testing = IdentityProductionConfiguration(
        linearSupersamplingScale: 1,
        toolchainIdentity: "test-toolchain"
    )
}

struct IdentityProductionLock: Codable, Equatable, Sendable {
    struct FileRecord: Codable, Equatable, Sendable {
        let id: String
        let path: String
        let sha256: String
    }

    struct ExporterFile: Codable, Equatable, Sendable {
        let path: String
        let sha256: String
    }

    struct Renderer: Codable, Equatable, Sendable {
        let colorSpace: String
        let cubicSampleCount: Int
        let lanczosRadius: Int
        let linearSupersamplingScale: Int
        let pixelFormat: String
        let supersamplingSamplesPerPixel: Int
        let toolchainContract: String
    }

    struct Output: Codable, Equatable, Sendable {
        let byteCount: Int
        let kind: String
        let path: String
        let pixelHeight: Int?
        let pixelWidth: Int?
        let pointSize: Int?
        let scale: Int?
        let sha256: String
        let templateRenderingIntent: Bool
    }

    let approvals: [ApprovedIdentitySelection.Approval]
    let assetCatalogPath: String
    let brand: String
    let exporterAggregateSHA256: String
    let exporterSources: [ExporterFile]
    let geometry: ApprovedIdentitySelection.Geometry
    let inputs: [FileRecord]
    let outputs: [Output]
    let palette: ApprovedIdentitySelection.Palette
    let renderer: Renderer
    let schemaVersion: Int
    let selection: FileRecord
    let status: String
    let trademarkTreatment: String
}
