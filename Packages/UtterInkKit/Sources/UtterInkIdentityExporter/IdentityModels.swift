import Foundation

struct IdentityInputPaths: Sendable {
    let sourceDirectory: URL
    let paletteFile: URL

    init(sourceDirectory: URL, paletteFile: URL) {
        self.sourceDirectory = sourceDirectory
        self.paletteFile = paletteFile
    }

    var repositoryRoot: URL {
        sourceDirectory
            .deletingLastPathComponent() // Brand
            .deletingLastPathComponent() // repository root
    }

    var provenanceFile: URL {
        sourceDirectory.appendingPathComponent("provenance.json", isDirectory: false)
    }
}

enum IdentityExporter {}

enum IdentityExporterError: Error, Equatable, CustomStringConvertible {
    case invalidInput(String)
    case mismatchedFiles([String])
    case unreadableInput(String)

    var description: String {
        switch self {
        case let .invalidInput(reason):
            return "invalid identity input: \(reason)"
        case let .mismatchedFiles(paths):
            return paths.sorted().joined(separator: "\n")
        case let .unreadableInput(name):
            return "unreadable identity input: \(name)"
        }
    }
}

struct VectorPoint: Equatable, Sendable {
    let x: Double
    let y: Double

    static func + (lhs: VectorPoint, rhs: VectorPoint) -> VectorPoint {
        VectorPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: VectorPoint, rhs: VectorPoint) -> VectorPoint {
        VectorPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: VectorPoint, rhs: Double) -> VectorPoint {
        VectorPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

struct ValidatedSVG: Equatable, Sendable {
    let viewBoxWidth: Double
    let viewBoxHeight: Double
    let bowlPolyline: [VectorPoint]
    let bowlSampleCount: Int
    let cursorStart: VectorPoint
    let cursorEnd: VectorPoint
    let bowlStrokeWidth: Double
    let cursorStrokeWidth: Double

    init(
        viewBoxWidth: Double,
        viewBoxHeight: Double,
        bowlPolyline: [VectorPoint],
        bowlSampleCount: Int,
        cursorStart: VectorPoint,
        cursorEnd: VectorPoint,
        bowlStrokeWidth: Double,
        cursorStrokeWidth: Double
    ) throws {
        guard viewBoxWidth == 24,
              viewBoxHeight == 24,
              bowlSampleCount == 128,
              bowlPolyline.count == bowlSampleCount + 3,
              bowlStrokeWidth == 3.2,
              cursorStrokeWidth == 2.4 else {
            throw IdentityExporterError.invalidInput("invalid validated SVG geometry")
        }
        self.viewBoxWidth = viewBoxWidth
        self.viewBoxHeight = viewBoxHeight
        self.bowlPolyline = bowlPolyline
        self.bowlSampleCount = bowlSampleCount
        self.cursorStart = cursorStart
        self.cursorEnd = cursorEnd
        self.bowlStrokeWidth = bowlStrokeWidth
        self.cursorStrokeWidth = cursorStrokeWidth
    }
}

struct ValidatedProvenance: Equatable, Sendable {
    struct Artifact: Equatable, Sendable {
        let id: String
        let repositoryPath: String
        let sha256: String
        let publicDistribution: Bool
    }

    let artifacts: [Artifact]

    func sha256(for id: String) -> String? {
        artifacts.first(where: { $0.id == id })?.sha256
    }
}

enum IdentityArtifactLock {
    static let selectedRouteSHA256 = "15963ac872c2385170408029c86b450c4e2bdfc3b1c970f88d945adb8e7c4f08"
    static let handoffSHA256 = "0464a616dad340ded1672781c014a4421c7f04779bd4c1af4f38877fc225d3aa"
    static let rightCursorSHA256 = "8bd098aedf9dee4bd5d1752eea513557a1bc756b78e82c00f647a8fc77932839"
    static let comparisonSHA256 = "5e02410fdac93b6e2fcde790e7afa55fea7556c3a0604041b4c786d13857b506"
    static let palettesSHA256 = "570fd1697c49bba9a961cc3f33b5bf012b1f70193264ad0c6e860ef1b0616746"
    static let approvedSelectionSHA256 = "0e9a8f11f059eb9beaa941ca058956959d36e280beb06f0f7cd1ed76c38c42fb"
    static let recordingStateSHA256 = "d571228027b9f3e86236f30eda79d5ce90aee03f35f02c6ebe7fe75017dd29fd"
    static let processingStateSHA256 = "b76594845c336da49196f797a7a4d60b166776a2b38af74004aa81ea5d43fd7c"
    static let successStateSHA256 = "94ac00cecd37c722484d039a2822e88a9873a020f9724eaca5014f6b347f7320"
    static let failureStateSHA256 = "3349900f7b9456125cb7413c16df4f08e75fe070e6380a0755c21c5dcbfd80c7"
    static let wordmarkSHA256 = "b00a37fb4941b7bc0bbcfcf9a68ce81d74ed91b44a36d43556e261ae1cea560d"
}
