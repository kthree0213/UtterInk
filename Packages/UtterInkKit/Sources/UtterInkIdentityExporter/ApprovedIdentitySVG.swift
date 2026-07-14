import Foundation

enum IdentityStateKind: String, CaseIterable, Sendable {
    case recording
    case processing
    case success
    case failure
}

struct IdentityVectorStroke: Equatable, Sendable {
    let subpaths: [[VectorPoint]]
    let width: Double
}

struct ApprovedIdentitySources: Sendable {
    let baseSVG: ValidatedSVG
    let states: [IdentityStateKind: [IdentityVectorStroke]]
}

extension IdentityExporter {
    static func loadApprovedIdentitySources(
        repositoryRoot: URL,
        selection: ApprovedIdentitySelection,
        canonicalSVG: ValidatedSVG
    ) throws -> ApprovedIdentitySources {
        let sourceByID = Dictionary(uniqueKeysWithValues: selection.sourceFamily.map { ($0.id, $0) })
        for expected in ApprovedIdentitySVGContract.all {
            guard let record = sourceByID[expected.id],
                  record.path == expected.relativePath,
                  record.sha256 == expected.sha256 else {
                throw IdentityExporterError.invalidInput("approved SVG source record changed")
            }
            let url = repositoryRoot.appendingPathComponent(record.path)
            let data = try SecureFileReader.readRegularFile(
                at: url,
                limit: 64 * 1_024,
                displayName: record.path
            )
            try validateApprovedSVG(data, contract: expected)
        }

        let base = try ValidatedSVG(
            viewBoxWidth: canonicalSVG.viewBoxWidth,
            viewBoxHeight: canonicalSVG.viewBoxHeight,
            bowlPolyline: canonicalSVG.bowlPolyline,
            bowlSampleCount: canonicalSVG.bowlSampleCount,
            cursorStart: VectorPoint(x: 18.8, y: 2.6),
            cursorEnd: VectorPoint(x: 18.8, y: 6.4),
            bowlStrokeWidth: canonicalSVG.bowlStrokeWidth,
            cursorStrokeWidth: canonicalSVG.cursorStrokeWidth
        )
        let bowl = IdentityVectorStroke(subpaths: [base.bowlPolyline], width: 3.2)
        let cursor = IdentityVectorStroke(
            subpaths: [[base.cursorStart, base.cursorEnd]],
            width: 2.4
        )
        return ApprovedIdentitySources(baseSVG: base, states: [
            .recording: [bowl, cursor],
            .processing: [
                bowl,
                .init(subpaths: [[.init(x: 18.8, y: 1.6), .init(x: 18.8, y: 2.8)]], width: 1),
                .init(subpaths: [[.init(x: 18.8, y: 5.8), .init(x: 18.8, y: 7)]], width: 1),
            ],
            .success: [
                bowl,
                cursor,
                .init(subpaths: [[
                    .init(x: 10, y: 13.8),
                    .init(x: 11.4, y: 15.2),
                    .init(x: 14, y: 12.4),
                ]], width: 1.4),
            ],
            .failure: [
                bowl,
                cursor,
                .init(subpaths: [
                    [.init(x: 10.5, y: 11.4), .init(x: 13.5, y: 14.4)],
                    [.init(x: 13.5, y: 11.4), .init(x: 10.5, y: 14.4)],
                ], width: 1.4),
            ],
        ])
    }

    private static func validateApprovedSVG(
        _ data: Data,
        contract: ApprovedIdentitySVGContract
    ) throws {
        guard sha256(data) == contract.sha256 else {
            throw IdentityExporterError.invalidInput("approved SVG SHA-256 mismatch")
        }
        guard let source = String(data: data, encoding: .utf8), Data(source.utf8) == data else {
            throw IdentityExporterError.invalidInput("approved SVG must be canonical UTF-8")
        }
        let lower = source.lowercased()
        for forbidden in [
            "<?", "<!--", "<!doctype", "<!entity", "<![cdata[", "<script", "<image",
            "<use", "<text", "<font", "<foreignobject", "href=", "style=", "onload=", "url(",
        ] where lower.contains(forbidden) {
            throw IdentityExporterError.invalidInput("approved SVG contains forbidden content")
        }

        let delegate = ApprovedSVGParserDelegate(contract: contract)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let parsed = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard parsed, parser.parserError == nil else {
            throw IdentityExporterError.invalidInput("approved SVG XML is malformed")
        }
        try delegate.finish()
    }
}

private struct ApprovedIdentitySVGContract {
    let id: String
    let relativePath: String
    let sha256: String
    let rootAttributes: [String: String]
    let pathAttributes: [[String: String]]?
    let requiredPathCount: Int

    static let bowl = [
        "d": "M5.2 4.6v8.8c0 4.4 2.7 7 6.8 7s6.8-2.6 6.8-7v-2.2",
        "stroke": "#111111",
        "stroke-width": "3.2",
        "stroke-linecap": "round",
        "stroke-linejoin": "round",
    ]
    static let cursor = [
        "d": "M18.8 2.6v3.8",
        "stroke": "#111111",
        "stroke-width": "2.4",
        "stroke-linecap": "round",
    ]
    static let stateRoot = ["viewBox": "0 0 24 24", "fill": "none"]

    static let all: [ApprovedIdentitySVGContract] = [
        .init(
            id: "recording-state",
            relativePath: "Brand/states/recording.svg",
            sha256: IdentityArtifactLock.recordingStateSHA256,
            rootAttributes: stateRoot,
            pathAttributes: [bowl, cursor],
            requiredPathCount: 2
        ),
        .init(
            id: "processing-state",
            relativePath: "Brand/states/processing.svg",
            sha256: IdentityArtifactLock.processingStateSHA256,
            rootAttributes: stateRoot,
            pathAttributes: [
                bowl,
                ["d": "M18.8 1.6v1.2", "stroke": "#111111", "stroke-width": "1", "stroke-linecap": "round"],
                ["d": "M18.8 5.8v1.2", "stroke": "#111111", "stroke-width": "1", "stroke-linecap": "round"],
            ],
            requiredPathCount: 3
        ),
        .init(
            id: "success-state",
            relativePath: "Brand/states/success.svg",
            sha256: IdentityArtifactLock.successStateSHA256,
            rootAttributes: stateRoot,
            pathAttributes: [
                bowl,
                cursor,
                [
                    "d": "M10 13.8l1.4 1.4 2.6-2.8", "stroke": "#111111",
                    "stroke-width": "1.4", "stroke-linecap": "round", "stroke-linejoin": "round",
                ],
            ],
            requiredPathCount: 3
        ),
        .init(
            id: "failure-state",
            relativePath: "Brand/states/failure.svg",
            sha256: IdentityArtifactLock.failureStateSHA256,
            rootAttributes: stateRoot,
            pathAttributes: [
                bowl,
                cursor,
                [
                    "d": "M10.5 11.4l3 3M13.5 11.4l-3 3", "stroke": "#111111",
                    "stroke-width": "1.4", "stroke-linecap": "round",
                ],
            ],
            requiredPathCount: 3
        ),
        .init(
            id: "wordmark-lockup",
            relativePath: "Brand/wordmark-lockup.svg",
            sha256: IdentityArtifactLock.wordmarkSHA256,
            rootAttributes: [
                "viewBox": "0 0 117 24", "fill": "none", "role": "img", "aria-label": "UtterInk",
            ],
            pathAttributes: nil,
            requiredPathCount: 11
        ),
    ]
}

private final class ApprovedSVGParserDelegate: NSObject, XMLParserDelegate {
    let contract: ApprovedIdentitySVGContract
    var failure: IdentityExporterError?
    private var depth = 0
    private var rootCount = 0
    private var paths: [[String: String]] = []
    private var mappings: [(String, String)] = []

    init(contract: ApprovedIdentitySVGContract) {
        self.contract = contract
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        mappings.append((prefix, namespaceURI))
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        guard namespaceURI == "http://www.w3.org/2000/svg", qName == elementName else {
            return reject(parser, "unexpected approved SVG namespace")
        }
        if depth == 0 {
            guard elementName == "svg", rootCount == 0, attributeDict == contract.rootAttributes else {
                return reject(parser, "approved SVG root changed")
            }
            rootCount = 1
        } else if depth == 1 {
            guard elementName == "path", paths.count < contract.requiredPathCount else {
                return reject(parser, "approved SVG child set changed")
            }
            if let expected = contract.pathAttributes, attributeDict != expected[paths.count] {
                return reject(parser, "approved SVG path geometry changed")
            }
            guard Set(attributeDict.keys).isSubset(of: [
                "d", "fill", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin",
            ]), attributeDict["d"] != nil else {
                return reject(parser, "approved SVG path attributes are unsafe")
            }
            paths.append(attributeDict)
        } else {
            return reject(parser, "nested approved SVG content is forbidden")
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil, depth > 0,
              namespaceURI == "http://www.w3.org/2000/svg", qName == elementName else {
            return reject(parser, "malformed approved SVG boundary")
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.allSatisfy(\.isWhitespace) { reject(parser, "approved SVG text is forbidden") }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { reject(parser, "CDATA is forbidden") }
    func parser(_ parser: XMLParser, foundComment comment: String) { reject(parser, "comments are forbidden") }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        reject(parser, "processing instructions are forbidden")
    }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser, "external entities are forbidden")
        return nil
    }

    func finish() throws {
        guard failure == nil, depth == 0, rootCount == 1,
              paths.count == contract.requiredPathCount,
              mappings.count == 1, mappings[0].0.isEmpty,
              mappings[0].1 == "http://www.w3.org/2000/svg" else {
            throw failure ?? IdentityExporterError.invalidInput("approved SVG structure is incomplete")
        }
    }

    private func reject(_ parser: XMLParser, _ reason: String) {
        guard failure == nil else { return }
        failure = .invalidInput(reason)
        parser.abortParsing()
    }
}
