#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let expectedHeader = [
    "legacy_domain",
    "legacy_key_or_pattern",
    "value_shape",
    "profile_mapping",
    "legacy_bundle_id",
    "new_bundle_id",
    "legacy_sandboxed",
    "keychain_access_group",
    "evidence_path",
    "evidence_hash",
]

private let importHeader = [
    "source_path",
    "destination_path",
    "sha256",
    "purpose",
    "copyright_owner",
    "license_or_authority",
    "reviewer",
]

private let legacyDomain = "dev.flowtype.FlowType"
private let newBundleID = "dev.utterink.UtterInk"
private let directEvidencePath = "LegacyParity/Sources/FlowType/Core/LLMProviderProfiles.swift"
private let directEvidenceHash = "6a6b32186bb53514f394e0ded6cae4feec02f8d67119a40e511629275e9b8553"
private let authorityOwner = "kthree0213"
private let authorityStatement = "Original author and sole copyright holder; authorized for Apache-2.0"
private let authorityReviewer = "kthree0213"

private struct CanonicalEntry {
    let key: String
    let valueShape: String
    let profileMapping: String
}

private let canonicalEntries = [
    CanonicalEntry(
        key: "llmProviderProfilesV1",
        valueShape: "non-secret-provider-profile-json",
        profileMapping: "provider-profile-list"
    ),
    CanonicalEntry(
        key: "llmP.<UUID>.apiKey",
        valueShape: "plaintext-secret",
        profileMapping: "direct-uuid"
    ),
    CanonicalEntry(
        key: "openRouterApiKey",
        valueShape: "plaintext-secret",
        profileMapping: "unique-provider:openrouter"
    ),
    CanonicalEntry(
        key: "minimaxApiKey",
        valueShape: "plaintext-secret",
        profileMapping: "unique-provider:minimax"
    ),
]

private struct SupportArtifact {
    let sourcePath: String
    let destinationPath: String
    let expectedHash: String
    let purpose: String
}

private let supportArtifacts = [
    SupportArtifact(
        sourcePath: "Packaging/Info.plist",
        destinationPath: "LegacyParity/Packaging/Info.plist",
        expectedHash: "09bc688f56336638040af2688bc5fbca713c5e73d645316aa81ae90107d75cfe",
        purpose: "parity-configuration"
    ),
    SupportArtifact(
        sourcePath: "Packaging/FlowType.entitlements",
        destinationPath: "LegacyParity/Packaging/FlowType.entitlements",
        expectedHash: "289696af9834a7ee41aca4c1cd3aa95fc38f9ae2e83655b1d4b86c1ccab771ee",
        purpose: "parity-configuration"
    ),
    SupportArtifact(
        sourcePath: "Scripts/package-dmg.sh",
        destinationPath: "LegacyParity/Scripts/package-dmg.sh",
        expectedHash: "66fc43c719b3e98b66f596c1cbd4e44de4e2d2851d3d831b0c45692be189fb60",
        purpose: "parity-tooling"
    ),
]

private struct MapEntry: Equatable {
    let legacyDomain: String
    let legacyKeyOrPattern: String
    let valueShape: String
    let profileMapping: String
    let legacyBundleID: String
    let newBundleID: String
    let legacySandboxed: Bool
    let keychainAccessGroup: String?
    let evidencePath: String
    let evidenceHash: String
}

private struct ImportRow {
    let sourcePath: String
    let destinationPath: String
    let hash: String
    let purpose: String
    let owner: String
    let authority: String
    let reviewer: String
}

private enum GeneratorError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private func fail(_ message: String) throws -> Never {
    throw GeneratorError.message(message)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func readData(_ url: URL, missingMessage: String) throws -> Data {
    guard FileManager.default.fileExists(atPath: url.path) else {
        try fail(missingMessage)
    }
    do {
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
        try fail(missingMessage)
    }
}

private func parseTable(data: Data, header: [String], label: String) throws -> [[String]] {
    guard data.last == 0x0A, let text = String(data: data, encoding: .utf8) else {
        try fail("\(label) must be canonical UTF-8 with a final newline")
    }
    guard !text.contains("\r") else {
        try fail("\(label) must use canonical LF line endings")
    }

    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" {
        lines.removeLast()
    }
    guard !lines.isEmpty else {
        try fail("\(label) is empty")
    }
    guard lines.allSatisfy({ !$0.isEmpty }) else {
        try fail("\(label) contains an empty row")
    }

    let actualHeader = lines[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard actualHeader == header else {
        try fail("\(label) has an invalid exact schema")
    }

    return try lines.dropFirst().enumerated().map { index, line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == header.count else {
            try fail("\(label) row \(index + 2) has an invalid field count")
        }
        return fields
    }
}

private func validatedEvidenceURL(path: String, root: URL) throws -> URL {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
        try fail("evidence_path must be a normal repository-relative evidence path")
    }

    let rootPath = root.path
    let candidate = root.appendingPathComponent(path, isDirectory: false)
    let standardized = candidate.path
    guard standardized.hasPrefix(rootPath + "/") else {
        try fail("evidence_path must be a normal repository-relative evidence path")
    }

    var componentURL = root
    for component in path.split(separator: "/").map(String.init) {
        componentURL.appendPathComponent(component)
        if FileManager.default.fileExists(atPath: componentURL.path) {
            let values = try componentURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                try fail("symlink evidence path is not allowed")
            }
        }
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        try fail("missing evidence artifact")
    }
    return candidate
}

private func parseMap(data: Data, root: URL) throws -> [MapEntry] {
    let fields = try parseTable(data: data, header: expectedHeader, label: "legacy defaults map")
    guard fields.count == canonicalEntries.count else {
        try fail("legacy defaults map must contain exactly four canonical rows")
    }

    let allowedKeys = Set(canonicalEntries.map(\.key))
    for row in fields where !allowedKeys.contains(row[1]) {
        try fail("unknown legacy key or pattern")
    }
    guard Set(fields.map { $0[1] }).count == fields.count else {
        try fail("duplicate mappings are not allowed")
    }
    guard Set(fields.map { $0[1] }) == allowedKeys else {
        try fail("legacy defaults map must contain the exact canonical row set")
    }
    guard fields.map({ $0[1] }) == canonicalEntries.map(\.key) else {
        try fail("legacy defaults map must use canonical row order")
    }

    var result: [MapEntry] = []
    for (index, row) in fields.enumerated() {
        _ = try validatedEvidenceURL(path: row[8], root: root)
        let expected = canonicalEntries[index]
        guard row[0] == legacyDomain,
              row[1] == expected.key,
              row[2] == expected.valueShape,
              row[3] == expected.profileMapping,
              row[4] == legacyDomain,
              row[5] == newBundleID,
              row[6] == "false",
              row[7].isEmpty,
              row[8] == directEvidencePath
        else {
            try fail("legacy defaults map row does not match its canonical mapping")
        }
        guard row[9].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            try fail("evidence_hash must be a lowercase SHA-256")
        }

        result.append(
            MapEntry(
                legacyDomain: row[0],
                legacyKeyOrPattern: row[1],
                valueShape: row[2],
                profileMapping: row[3],
                legacyBundleID: row[4],
                newBundleID: row[5],
                legacySandboxed: false,
                keychainAccessGroup: nil,
                evidencePath: row[8],
                evidenceHash: row[9]
            )
        )
    }
    guard Set(result.map(\.evidenceHash)).count == 1 else {
        try fail("duplicate mappings cite inconsistent evidence hashes")
    }
    return result
}

private func parseImportManifest(data: Data) throws -> [String: ImportRow] {
    let fields = try parseTable(data: data, header: importHeader, label: "legacy source import manifest")
    var result: [String: ImportRow] = [:]
    for row in fields {
        guard !row[0].isEmpty, !row[1].isEmpty, !row[2].isEmpty, !row[3].isEmpty,
              !row[4].isEmpty, !row[5].isEmpty, !row[6].isEmpty
        else {
            try fail("incomplete import rights or evidence")
        }
        guard result[row[1]] == nil else {
            try fail("duplicate import manifest destination")
        }
        result[row[1]] = ImportRow(
            sourcePath: row[0],
            destinationPath: row[1],
            hash: row[2],
            purpose: row[3],
            owner: row[4],
            authority: row[5],
            reviewer: row[6]
        )
    }
    return result
}

private func validateManifestRow(
    _ row: ImportRow?,
    sourcePath: String,
    destinationPath: String,
    purpose: String
) throws -> ImportRow {
    guard let row else {
        try fail("missing corresponding import manifest evidence")
    }
    guard row.sourcePath == sourcePath,
          row.destinationPath == destinationPath,
          row.purpose == purpose,
          row.owner == authorityOwner,
          row.authority == authorityStatement,
          row.reviewer == authorityReviewer
    else {
        try fail("incomplete import rights or evidence")
    }
    guard row.hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
        try fail("incomplete import rights or evidence")
    }
    return row
}

private func validateSecretLookingLiterals(_ data: Data) throws {
    guard let source = String(data: data, encoding: .utf8) else {
        try fail("direct evidence must be UTF-8 Swift source")
    }
    let expression = try NSRegularExpression(pattern: #"\"((?:\\.|[^\"\\])*)\""#)
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let allowed = Set([
        "llmP.\\(id.uuidString).apiKey",
        "openRouterApiKey",
        "minimaxApiKey",
    ])
    let secretMarkers = ["apikey", "api_key", "token", "secret", "password", "credential"]
    for match in expression.matches(in: source, range: range) {
        guard let capture = Range(match.range(at: 1), in: source) else { continue }
        let literal = String(source[capture])
        let folded = literal.lowercased()
        if secretMarkers.contains(where: folded.contains), !allowed.contains(literal) {
            try fail("undocumented secret-looking defaults literal")
        }
    }
}

private func validateInfoPlist(_ data: Data) throws {
    let object: Any
    do {
        object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
        try fail("legacy Info.plist is invalid")
    }
    guard let dictionary = object as? [String: Any],
          dictionary["CFBundleIdentifier"] as? String == legacyDomain
    else {
        try fail("legacy bundle identifier does not match the authority map")
    }
}

private func validateEntitlements(_ data: Data) throws {
    let object: Any
    do {
        object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    } catch {
        try fail("legacy entitlements are invalid")
    }
    guard let dictionary = object as? [String: Any] else {
        try fail("legacy entitlements are invalid")
    }
    guard dictionary["com.apple.security.app-sandbox"] == nil else {
        try fail("legacy app sandbox must be absent")
    }
    guard dictionary["keychain-access-groups"] == nil,
          dictionary["com.apple.security.keychain-access-groups"] == nil
    else {
        try fail("legacy Keychain access group must be absent")
    }
    guard dictionary.count == 1,
          dictionary["com.apple.security.device.audio-input"] as? Bool == true
    else {
        try fail("legacy entitlements contain unsupported capabilities")
    }
}

private func validateSigningScript(_ data: Data) throws {
    guard let script = String(data: data, encoding: .utf8) else {
        try fail("legacy signing script must be UTF-8")
    }
    let assignment = #"ENTITLEMENTS="$ROOT/Packaging/FlowType.entitlements""#
    let pattern = #"codesign\s+--force\s+--deep\s+--sign\s+"\$IDENTITY"\s+--options\s+runtime\s+--entitlements\s+"\$ENTITLEMENTS"\s+"\$APP""#
    guard script.contains(assignment), script.range(of: pattern, options: .regularExpression) != nil else {
        try fail("signing script entitlements/runtime relationship is invalid")
    }
}

private func swiftStringLiteral(_ value: String) -> String {
    var escaped = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22:
            escaped += "\\\""
        case 0x5C:
            escaped += "\\\\"
        case 0x0A:
            escaped += "\\n"
        case 0x0D:
            escaped += "\\r"
        case 0x09:
            escaped += "\\t"
        case 0x00:
            escaped += "\\0"
        case 0x01...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F, 0x2028, 0x2029:
            escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        default:
            escaped.unicodeScalars.append(scalar)
        }
    }
    escaped += "\""
    return escaped
}

private func renderSwift(
    entries: [MapEntry],
    authorityHash: String,
    supportHashes: [(String, String)]
) -> Data {
    var lines: [String] = [
        "// Generated by Scripts/generate-legacy-defaults-map.swift. Do not edit.",
        "import Foundation",
        "",
        "public struct LegacyDefaultsMap: Sendable {",
        "    public struct Entry: Equatable, Sendable {",
        "        public let legacyDomain: String",
        "        public let legacyKeyOrPattern: String",
        "        public let valueShape: String",
        "        public let profileMapping: String",
        "        public let legacyBundleID: String",
        "        public let newBundleID: String",
        "        public let legacySandboxed: Bool",
        "        public let keychainAccessGroup: String?",
        "        public let evidencePath: String",
        "        public let evidenceHash: String",
        "",
        "        package init(",
        "            legacyDomain: String,",
        "            legacyKeyOrPattern: String,",
        "            valueShape: String,",
        "            profileMapping: String,",
        "            legacyBundleID: String,",
        "            newBundleID: String,",
        "            legacySandboxed: Bool,",
        "            keychainAccessGroup: String?,",
        "            evidencePath: String,",
        "            evidenceHash: String",
        "        ) {",
        "            self.legacyDomain = legacyDomain",
        "            self.legacyKeyOrPattern = legacyKeyOrPattern",
        "            self.valueShape = valueShape",
        "            self.profileMapping = profileMapping",
        "            self.legacyBundleID = legacyBundleID",
        "            self.newBundleID = newBundleID",
        "            self.legacySandboxed = legacySandboxed",
        "            self.keychainAccessGroup = keychainAccessGroup",
        "            self.evidencePath = evidencePath",
        "            self.evidenceHash = evidenceHash",
        "        }",
        "    }",
        "",
        "    public let entries: [Entry]",
        "    public let authorityHash: String",
        "    public let supportEvidenceHashes: [String: String]",
        "",
        "    package init(entries: [Entry], authorityHash: String, supportEvidenceHashes: [String: String]) {",
        "        self.entries = entries",
        "        self.authorityHash = authorityHash",
        "        self.supportEvidenceHashes = supportEvidenceHashes",
        "    }",
        "",
        "    public static let bundled = LegacyDefaultsMap(",
        "        entries: [",
    ]

    for entry in entries {
        lines.append(contentsOf: [
            "            Entry(",
            "                legacyDomain: \(swiftStringLiteral(entry.legacyDomain)),",
            "                legacyKeyOrPattern: \(swiftStringLiteral(entry.legacyKeyOrPattern)),",
            "                valueShape: \(swiftStringLiteral(entry.valueShape)),",
            "                profileMapping: \(swiftStringLiteral(entry.profileMapping)),",
            "                legacyBundleID: \(swiftStringLiteral(entry.legacyBundleID)),",
            "                newBundleID: \(swiftStringLiteral(entry.newBundleID)),",
            "                legacySandboxed: \(entry.legacySandboxed),",
            "                keychainAccessGroup: \(entry.keychainAccessGroup.map(swiftStringLiteral) ?? "nil"),",
            "                evidencePath: \(swiftStringLiteral(entry.evidencePath)),",
            "                evidenceHash: \(swiftStringLiteral(entry.evidenceHash))",
            "            ),",
        ])
    }

    lines.append(contentsOf: [
        "        ],",
        "        authorityHash: \(swiftStringLiteral(authorityHash)),",
        "        supportEvidenceHashes: [",
    ])
    for (path, hash) in supportHashes {
        lines.append("            \(swiftStringLiteral(path)): \(swiftStringLiteral(hash)),")
    }
    lines.append(contentsOf: [
        "        ]",
        "    )",
        "}",
        "",
    ])
    return Data(lines.joined(separator: "\n").utf8)
}

private enum Action {
    case emit(input: String, output: String)
    case check(input: String, output: String)
    case escapeTest(String)
}

private func parseArguments(_ arguments: [String]) throws -> Action {
    if arguments.first == "--escape-test" {
        guard arguments.count == 2 else {
            try fail("usage: --escape-test <value>")
        }
        return .escapeTest(arguments[1])
    }

    var mode: String?
    var input: String?
    var output: String?
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--emit", "--check":
            guard mode == nil else { try fail("choose exactly one of --emit or --check") }
            mode = arguments[index]
            index += 1
        case "--input":
            guard index + 1 < arguments.count, input == nil else { try fail("invalid --input") }
            input = arguments[index + 1]
            index += 2
        case "--swift-output":
            guard index + 1 < arguments.count, output == nil else { try fail("invalid --swift-output") }
            output = arguments[index + 1]
            index += 2
        default:
            try fail("unknown argument")
        }
    }
    guard let mode, let input, let output else {
        try fail("usage: (--emit|--check) --input <tsv> --swift-output <swift>")
    }
    return mode == "--emit" ? .emit(input: input, output: output) : .check(input: input, output: output)
}

private func fileURL(path: String, root: URL) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
}

private func generate(inputPath: String, root: URL) throws -> Data {
    let inputURL = fileURL(path: inputPath, root: root)
    let inputData = try readData(inputURL, missingMessage: "missing legacy defaults map")
    let entries = try parseMap(data: inputData, root: root)

    let manifestURL = root.appendingPathComponent("docs/provenance/legacy-source-import.tsv")
    let manifestData = try readData(manifestURL, missingMessage: "missing legacy source import manifest")
    let manifest = try parseImportManifest(data: manifestData)

    let directRow = try validateManifestRow(
        manifest[directEvidencePath],
        sourcePath: "Sources/FlowType/Core/LLMProviderProfiles.swift",
        destinationPath: directEvidencePath,
        purpose: "parity-source"
    )
    var requiredRows: [(SupportArtifact, ImportRow)] = []
    for artifact in supportArtifacts {
        let row = try validateManifestRow(
            manifest[artifact.destinationPath],
            sourcePath: artifact.sourcePath,
            destinationPath: artifact.destinationPath,
            purpose: artifact.purpose
        )
        requiredRows.append((artifact, row))
    }

    let directURL = try validatedEvidenceURL(path: directEvidencePath, root: root)
    let directData = try readData(directURL, missingMessage: "missing evidence artifact")
    let actualDirectHash = sha256(directData)
    guard directRow.hash == actualDirectHash,
          entries.allSatisfy({ $0.evidenceHash == actualDirectHash })
    else {
        try fail("evidence hash drift")
    }

    var supportData: [String: Data] = [:]
    var supportHashes: [(String, String)] = []
    for (artifact, row) in requiredRows {
        let url = try validatedEvidenceURL(path: artifact.destinationPath, root: root)
        let data = try readData(url, missingMessage: "missing evidence artifact")
        let actualHash = sha256(data)
        guard row.hash == actualHash else {
            try fail("evidence hash drift")
        }
        supportData[artifact.destinationPath] = data
        supportHashes.append((artifact.destinationPath, actualHash))
    }

    try validateSecretLookingLiterals(directData)
    try validateInfoPlist(supportData["LegacyParity/Packaging/Info.plist"] ?? Data())
    try validateEntitlements(supportData["LegacyParity/Packaging/FlowType.entitlements"] ?? Data())
    try validateSigningScript(supportData["LegacyParity/Scripts/package-dmg.sh"] ?? Data())

    guard actualDirectHash == directEvidenceHash else {
        try fail("evidence hash drift from fixed direct-key authority")
    }
    for (artifact, row) in requiredRows {
        guard row.hash == artifact.expectedHash else {
            try fail("evidence hash drift from fixed packaging authority")
        }
    }

    return renderSwift(
        entries: entries,
        authorityHash: sha256(inputData),
        supportHashes: supportHashes
    )
}

do {
    let action = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    switch action {
    case .escapeTest(let value):
        print(swiftStringLiteral(value))
    case .emit(let input, let output):
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let generated = try generate(inputPath: input, root: root)
        let outputURL = fileURL(path: output, root: root)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try generated.write(to: outputURL, options: .atomic)
    case .check(let input, let output):
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let generated = try generate(inputPath: input, root: root)
        let outputURL = fileURL(path: output, root: root)
        guard let checkedIn = try? Data(contentsOf: outputURL), checkedIn == generated else {
            try fail("stale generated Swift output")
        }
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
