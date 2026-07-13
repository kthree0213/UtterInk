import Foundation
import UtterInkCore

public enum DiagnosticPermissionState: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case denied
    case granted
}

public enum DiagnosticComponent: String, Codable, CaseIterable, Hashable, Sendable {
    case audio
    case speechModel
    case transcription
    case history
    case credential
    case polishing
    case delivery
    case permissions
}

public enum DiagnosticModelPhase: String, Codable, CaseIterable, Sendable {
    case missing
    case downloading
    case loading
    case ready
    case failed
}

public enum DiagnosticArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64
    case unknown
}

public struct DiagnosticEventCount: Encodable, Equatable, Sendable {
    public let component: DiagnosticComponent
    public let count: Int

    public init(component: DiagnosticComponent, count: Int) {
        self.component = component
        self.count = min(max(0, count), SafeDiagnosticsSummary.maximumEventCount)
    }
}

public struct SafeDiagnosticsSummary: Encodable, Equatable, Sendable {
    static let maximumEventCount = 10_000
    private static let maximumCodes = 32

    public let lastStage: PipelineStage
    public let diagnosticCodes: [DiagnosticCode]
    public let eventCounts: [DiagnosticEventCount]

    public init(
        lastStage: PipelineStage,
        diagnosticCodes: [DiagnosticCode],
        eventCounts: [DiagnosticEventCount]
    ) {
        self.lastStage = lastStage

        var seenCodes = Set<String>()
        self.diagnosticCodes = diagnosticCodes
            .filter { seenCodes.insert($0.rawValue).inserted }
            .sorted { $0.rawValue < $1.rawValue }
            .prefix(Self.maximumCodes)
            .map { $0 }

        var totals: [DiagnosticComponent: Int] = [:]
        for event in eventCounts {
            let current = totals[event.component, default: 0]
            totals[event.component] = min(
                Self.maximumEventCount,
                current + event.count
            )
        }
        self.eventCounts = DiagnosticComponent.allCases.compactMap { component in
            guard let count = totals[component], count > 0 else { return nil }
            return DiagnosticEventCount(component: component, count: count)
        }
    }
}

public struct DiagnosticsSnapshot: Encodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appVersion: String
    public let appBuild: String
    public let operatingSystemVersion: String
    public let architecture: DiagnosticArchitecture
    public let microphonePermission: DiagnosticPermissionState
    public let accessibilityPermission: DiagnosticPermissionState
    public let speechModelID: String
    public let speechModelPhase: DiagnosticModelPhase
    public let providerHost: String?
    public let providerModelID: String?
    public let lastStage: PipelineStage
    public let historyEnabled: Bool
    public let historyItemCount: Int
    public let diagnosticCodes: [DiagnosticCode]
    public let eventCounts: [DiagnosticEventCount]

    public init(
        appVersion: String,
        appBuild: String,
        operatingSystemVersion: String,
        architecture: DiagnosticArchitecture,
        microphonePermission: DiagnosticPermissionState,
        accessibilityPermission: DiagnosticPermissionState,
        speechModelID: String,
        speechModelPhase: DiagnosticModelPhase,
        providerHost: String?,
        providerModelID: String?,
        historyEnabled: Bool,
        historyItemCount: Int,
        summary: SafeDiagnosticsSummary
    ) {
        schemaVersion = 1
        self.appVersion = DiagnosticValueSanitizer.versionValue(appVersion)
        self.appBuild = DiagnosticValueSanitizer.buildNumber(appBuild)
        self.operatingSystemVersion = DiagnosticValueSanitizer.versionValue(operatingSystemVersion)
        self.architecture = architecture
        self.microphonePermission = microphonePermission
        self.accessibilityPermission = accessibilityPermission
        self.speechModelID = DiagnosticValueSanitizer.modelIdentifier(speechModelID)
        self.speechModelPhase = speechModelPhase
        self.providerHost = providerHost.map(DiagnosticValueSanitizer.normalizedHost)
        self.providerModelID = providerModelID.map(DiagnosticValueSanitizer.modelIdentifier)
        self.lastStage = summary.lastStage
        self.historyEnabled = historyEnabled
        self.historyItemCount = min(max(0, historyItemCount), 10_000)
        diagnosticCodes = summary.diagnosticCodes
        eventCounts = summary.eventCounts
    }
}

public struct DiagnosticsExporter: Sendable {
    public init() {}

    public func export(_ snapshot: DiagnosticsSnapshot) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(snapshot) else {
            return Data("{\n  \"schemaVersion\" : 1\n}\n".utf8)
        }
        data.append(0x0A)
        return data
    }
}

enum DiagnosticValueSanitizer {
    private static let invalidBuildValue = "redacted-invalid-build-value"
    private static let invalidModelID = "redacted-invalid-model-id"
    private static let invalidHost = "redacted-invalid-host"
    private static let modelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )

    static func versionValue(_ candidate: String) -> String {
        guard candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              candidate.utf8.count <= 32 else {
            return invalidBuildValue
        }
        let segments = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty,
              segments.count <= 6,
              segments.allSatisfy({ segment in
                  !segment.isEmpty && segment.count <= 6 && segment.allSatisfy {
                      $0.isASCII && $0.isNumber
                  }
              }) else {
            return invalidBuildValue
        }
        return candidate
    }

    static func buildNumber(_ candidate: String) -> String {
        guard candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              candidate.utf8.count <= 16,
              candidate.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return invalidBuildValue
        }
        return candidate
    }

    static func modelIdentifier(_ candidate: String) -> String {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate == value,
              !value.isEmpty,
              value.utf8.count <= 96,
              isASCII(value, within: modelCharacters),
              !matchesKnownToken(value),
              !isCredentialShaped(value),
              !isHighEntropyKey(value) else {
            return invalidModelID
        }
        return value
    }

    static func normalizedHost(_ candidate: String) -> String {
        var value = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.last == "." { value.removeLast() }
        guard !value.isEmpty,
              value.utf8.count <= 253,
              !matchesKnownToken(value),
              !isCredentialShaped(value),
              !isHighEntropyKey(value) else { return invalidHost }
        if value == "localhost" || value == "::1" { return value }
        guard isASCII(value, within: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")),
              !value.contains("..") else {
            return invalidHost
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy({ label in
                  guard !label.isEmpty, label.utf8.count <= 63,
                        label.first != "-", label.last != "-" else { return false }
                  return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else {
            return invalidHost
        }
        return value
    }

    private static func isASCII(_ value: String, within allowed: CharacterSet) -> Bool {
        value.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func isCredentialShaped(_ value: String) -> Bool {
        let lowered = value.lowercased()
        let prefixes = [
            "sk-", "pk-", "bearer", "authorization", "api-key", "api_key",
            "apikey", "token", "secret", "gsk_", "hf_", "xai-"
        ]
        return prefixes.contains { lowered.hasPrefix($0) }
    }

    private static func matchesKnownToken(_ value: String) -> Bool {
        let patterns = [
            #"(?:AKIA|ASIA)[0-9A-Z]{16}"#,
            #"github_pat_[A-Za-z0-9_]{20,}"#,
            #"gh[pousr]_[A-Za-z0-9]{20,}"#,
            #"xox[baprs]-[A-Za-z0-9-]{10,}"#,
            #"sk_(?:live|test)_[A-Za-z0-9]{16,}"#,
            #"AIza[0-9A-Za-z_-]{30,}"#,
            #"sk-or-v1-[A-Za-z0-9_-]{20,}"#,
            #"sk-proj-[A-Za-z0-9_-]{20,}"#,
            #"sk-ant-[A-Za-z0-9_-]{20,}"#,
            #"gsk_[A-Za-z0-9_-]{20,}"#,
            #"hf_[A-Za-z0-9_-]{20,}"#,
            #"xai-[A-Za-z0-9_-]{20,}"#
        ]
        let range = NSRange(value.startIndex..., in: value)
        return patterns.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
            return expression.firstMatch(in: value, range: range) != nil
        }
    }

    private static func isHighEntropyKey(_ value: String) -> Bool {
        let payload = value.filter { $0 != "." && $0 != "_" && $0 != "-" }
        guard payload.utf8.count >= 24 else { return false }
        var frequencies: [Character: Int] = [:]
        for character in payload { frequencies[character, default: 0] += 1 }
        let length = Double(payload.count)
        let entropy = frequencies.values.reduce(0.0) { partial, count in
            let probability = Double(count) / length
            return partial - probability * log2(probability)
        }
        let classes = [
            payload.contains(where: \.isLowercase),
            payload.contains(where: \.isUppercase),
            payload.contains(where: \.isNumber)
        ].filter { $0 }.count
        return entropy >= 4.0 && classes >= 2
    }
}
