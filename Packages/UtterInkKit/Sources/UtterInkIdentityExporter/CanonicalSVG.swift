import CryptoKit
import Foundation

extension IdentityExporter {
    @discardableResult
    static func validateCanonicalSVG(
        _ data: Data,
        expectedSHA256: String
    ) throws -> ValidatedSVG {
        guard data.count > 0, data.count <= 16 * 1_024 else {
            throw IdentityExporterError.invalidInput("SVG size is outside the reviewed boundary")
        }
        guard sha256(data) == expectedSHA256.lowercased() else {
            throw IdentityExporterError.invalidInput("SVG SHA-256 mismatch")
        }
        guard let source = String(data: data, encoding: .utf8),
              Data(source.utf8) == data else {
            throw IdentityExporterError.invalidInput("SVG must be canonical UTF-8")
        }

        for forbidden in ["<?", "<!--", "<!DOCTYPE", "<!ENTITY", "<![CDATA["] {
            guard !source.contains(forbidden) else {
                throw IdentityExporterError.invalidInput("SVG contains a forbidden XML construct")
            }
        }

        let delegate = CanonicalSVGParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let parsed = parser.parse()
        if let failure = delegate.failure {
            throw failure
        }
        guard parsed, parser.parserError == nil else {
            throw IdentityExporterError.invalidInput("SVG XML is malformed")
        }
        return try delegate.finish()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CanonicalSVGParserDelegate: NSObject, XMLParserDelegate {
    private static let namespace = "http://www.w3.org/2000/svg"
    private static let bowlAttributes = [
        "d": "M5.2 4.6v8.8c0 4.4 2.7 7 6.8 7s6.8-2.6 6.8-7v-2.2",
        "stroke": "#111111",
        "stroke-width": "3.2",
        "stroke-linecap": "round",
        "stroke-linejoin": "round",
    ]
    private static let cursorAttributes = [
        "d": "M18.8 4.6v3.8",
        "stroke": "#111111",
        "stroke-width": "2.4",
        "stroke-linecap": "round",
    ]

    fileprivate var failure: IdentityExporterError?
    private var depth = 0
    private var rootCount = 0
    private var pathAttributes: [[String: String]] = []
    private var namespaceMappings: [(String, String)] = []

    func parser(
        _ parser: XMLParser,
        didStartMappingPrefix prefix: String,
        toURI namespaceURI: String
    ) {
        namespaceMappings.append((prefix, namespaceURI))
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        guard namespaceURI == Self.namespace, qName == elementName else {
            reject(parser, "unexpected SVG namespace")
            return
        }

        if depth == 0 {
            guard elementName == "svg",
                  rootCount == 0,
                  attributeDict == ["viewBox": "0 0 24 24", "fill": "none"] else {
                reject(parser, "root SVG contract mismatch")
                return
            }
            rootCount += 1
        } else if depth == 1 {
            guard elementName == "path", pathAttributes.count < 2 else {
                reject(parser, "SVG must contain exactly two direct path children")
                return
            }
            let expected = pathAttributes.isEmpty ? Self.bowlAttributes : Self.cursorAttributes
            guard attributeDict == expected else {
                reject(parser, "reviewed path attributes changed")
                return
            }
            pathAttributes.append(attributeDict)
        } else {
            reject(parser, "nested SVG content is forbidden")
            return
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        guard depth > 0, namespaceURI == Self.namespace, qName == elementName else {
            reject(parser, "malformed SVG element boundary")
            return
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard string.allSatisfy({ $0.isWhitespace }) else {
            reject(parser, "text nodes are forbidden")
            return
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        reject(parser, "CDATA is forbidden")
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        reject(parser, "comments are forbidden")
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        reject(parser, "processing instructions are forbidden")
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        reject(parser, "entity declarations are forbidden")
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        reject(parser, "external entities are forbidden")
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        reject(parser, "external entity resolution is forbidden")
        return nil
    }

    fileprivate func finish() throws -> ValidatedSVG {
        guard failure == nil,
              depth == 0,
              rootCount == 1,
              pathAttributes.count == 2,
              namespaceMappings.count == 1,
              namespaceMappings[0].0.isEmpty,
              namespaceMappings[0].1 == Self.namespace else {
            throw failure ?? IdentityExporterError.invalidInput("incomplete SVG structure")
        }

        let bowl = try SVGPathDecoder.decodeBowl(pathAttributes[0]["d"] ?? "")
        let cursor = try SVGPathDecoder.decodeCursor(pathAttributes[1]["d"] ?? "")
        return try ValidatedSVG(
            viewBoxWidth: 24,
            viewBoxHeight: 24,
            bowlPolyline: bowl.polyline,
            bowlSampleCount: bowl.sampleCount,
            cursorStart: cursor.0,
            cursorEnd: cursor.1,
            bowlStrokeWidth: 3.2,
            cursorStrokeWidth: 2.4
        )
    }

    private func reject(_ parser: XMLParser, _ reason: String) {
        guard failure == nil else { return }
        failure = .invalidInput(reason)
        parser.abortParsing()
    }
}

private enum SVGPathDecoder {
    struct Bowl {
        let polyline: [VectorPoint]
        let sampleCount: Int
    }

    static func decodeBowl(_ source: String) throws -> Bowl {
        var tokens = try SVGPathTokenizer(source).tokens()
        var index = 0
        var current = VectorPoint(x: 0, y: 0)
        var lastCubicControl: VectorPoint?
        var polyline: [VectorPoint] = []
        var samples: [VectorPoint] = []

        try expectCommand("M", in: tokens, at: &index)
        current = try VectorPoint(
            x: number(in: tokens, at: &index),
            y: number(in: tokens, at: &index)
        )
        polyline.append(current)

        try expectCommand("v", in: tokens, at: &index)
        current = current + VectorPoint(x: 0, y: try number(in: tokens, at: &index))
        polyline.append(current)

        try expectCommand("c", in: tokens, at: &index)
        let firstStart = current
        let firstControl1 = current + (try point(in: tokens, at: &index))
        let firstControl2 = current + (try point(in: tokens, at: &index))
        let firstEnd = current + (try point(in: tokens, at: &index))
        let firstSamples = cubicSamples(
            start: firstStart,
            control1: firstControl1,
            control2: firstControl2,
            end: firstEnd,
            count: 64
        )
        samples.append(contentsOf: firstSamples)
        polyline.append(contentsOf: firstSamples)
        current = firstEnd
        lastCubicControl = firstControl2

        try expectCommand("s", in: tokens, at: &index)
        guard let priorControl = lastCubicControl else {
            throw IdentityExporterError.invalidInput("smooth cubic has no prior control")
        }
        let secondStart = current
        let secondControl1 = current * 2 - priorControl
        let secondControl2 = current + (try point(in: tokens, at: &index))
        let secondEnd = current + (try point(in: tokens, at: &index))
        let secondSamples = cubicSamples(
            start: secondStart,
            control1: secondControl1,
            control2: secondControl2,
            end: secondEnd,
            count: 64
        )
        samples.append(contentsOf: secondSamples)
        polyline.append(contentsOf: secondSamples)
        current = secondEnd

        try expectCommand("v", in: tokens, at: &index)
        current = current + VectorPoint(x: 0, y: try number(in: tokens, at: &index))
        polyline.append(current)

        guard index == tokens.count, samples.count == 128 else {
            throw IdentityExporterError.invalidInput("unexpected bowl path commands")
        }
        tokens.removeAll(keepingCapacity: false)
        return Bowl(polyline: polyline, sampleCount: samples.count)
    }

    static func decodeCursor(_ source: String) throws -> (VectorPoint, VectorPoint) {
        let tokens = try SVGPathTokenizer(source).tokens()
        var index = 0
        try expectCommand("M", in: tokens, at: &index)
        let start = try VectorPoint(
            x: number(in: tokens, at: &index),
            y: number(in: tokens, at: &index)
        )
        try expectCommand("v", in: tokens, at: &index)
        let end = start + VectorPoint(x: 0, y: try number(in: tokens, at: &index))
        guard index == tokens.count else {
            throw IdentityExporterError.invalidInput("unexpected cursor path commands")
        }
        return (start, end)
    }

    private static func cubicSamples(
        start: VectorPoint,
        control1: VectorPoint,
        control2: VectorPoint,
        end: VectorPoint,
        count: Int
    ) -> [VectorPoint] {
        (1...count).map { step in
            let t = Double(step) / Double(count)
            let u = 1 - t
            return start * (u * u * u)
                + control1 * (3 * u * u * t)
                + control2 * (3 * u * t * t)
                + end * (t * t * t)
        }
    }

    private static func point(in tokens: [SVGPathToken], at index: inout Int) throws -> VectorPoint {
        try VectorPoint(x: number(in: tokens, at: &index), y: number(in: tokens, at: &index))
    }

    private static func expectCommand(
        _ command: Character,
        in tokens: [SVGPathToken],
        at index: inout Int
    ) throws {
        guard index < tokens.count, tokens[index] == .command(command) else {
            throw IdentityExporterError.invalidInput("unexpected SVG path command")
        }
        index += 1
    }

    private static func number(in tokens: [SVGPathToken], at index: inout Int) throws -> Double {
        guard index < tokens.count, case let .number(value) = tokens[index], value.isFinite else {
            throw IdentityExporterError.invalidInput("invalid SVG path number")
        }
        index += 1
        return value
    }
}

private enum SVGPathToken: Equatable {
    case command(Character)
    case number(Double)
}

private struct SVGPathTokenizer {
    let bytes: [UInt8]

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    func tokens() throws -> [SVGPathToken] {
        var result: [SVGPathToken] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 44 {
                index += 1
                continue
            }
            if let scalar = UnicodeScalar(Int(byte)), ["M", "v", "c", "s"].contains(Character(scalar)) {
                result.append(.command(Character(scalar)))
                index += 1
                continue
            }

            let start = index
            if bytes[index] == 45 { index += 1 }
            let integerStart = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            guard index > integerStart else {
                throw IdentityExporterError.invalidInput("invalid SVG path token")
            }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                let fractionStart = index
                while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
                guard index > fractionStart else {
                    throw IdentityExporterError.invalidInput("invalid SVG decimal")
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.hasPrefix("-0"), let value = Double(text), value.isFinite else {
                throw IdentityExporterError.invalidInput("invalid SVG numeric value")
            }
            result.append(.number(value))
        }
        return result
    }
}
