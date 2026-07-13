import Foundation
import XCTest
import UtterInkCore
@testable import UtterInkServices

final class DiagnosticsRedactionTests: XCTestCase {
    func testExporterContainsOnlyAllowlistedValuesInStablePrettyJSON() throws {
        let summary = SafeDiagnosticsSummary(
            lastStage: .delivering,
            diagnosticCodes: [.deliveryTargetChanged, .polishTransport],
            eventCounts: [
                DiagnosticEventCount(component: .delivery, count: 2),
                DiagnosticEventCount(component: .polishing, count: 1)
            ]
        )
        let snapshot = DiagnosticsSnapshot(
            appVersion: "1.2.3",
            appBuild: "42",
            operatingSystemVersion: "14.6.1",
            architecture: .arm64,
            microphonePermission: .granted,
            accessibilityPermission: .denied,
            speechModelID: "openai_whisper-small",
            speechModelPhase: .ready,
            providerHost: "API.Example.Test.",
            providerModelID: "gpt-4o-mini",
            historyEnabled: true,
            historyItemCount: 7,
            summary: summary
        )

        let data = DiagnosticsExporter().export(snapshot)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"))
        XCTAssertTrue(text.contains("\"appVersion\" : \"1.2.3\""))
        XCTAssertTrue(text.contains("\"appBuild\" : \"42\""))
        XCTAssertTrue(text.contains("\"operatingSystemVersion\" : \"14.6.1\""))
        XCTAssertTrue(text.contains("\"architecture\" : \"arm64\""))
        XCTAssertTrue(text.contains("\"microphonePermission\" : \"granted\""))
        XCTAssertTrue(text.contains("\"accessibilityPermission\" : \"denied\""))
        XCTAssertTrue(text.contains("\"speechModelID\" : \"openai_whisper-small\""))
        XCTAssertTrue(text.contains("\"speechModelPhase\" : \"ready\""))
        XCTAssertTrue(text.contains("\"providerHost\" : \"api.example.test\""))
        XCTAssertTrue(text.contains("\"providerModelID\" : \"gpt-4o-mini\""))
        XCTAssertTrue(text.contains("\"lastStage\" : \"delivering\""))
        XCTAssertTrue(text.contains("\"historyEnabled\" : true"))
        XCTAssertTrue(text.contains("\"historyItemCount\" : 7"))
        XCTAssertTrue(text.contains("delivery.target_changed"))
        XCTAssertTrue(text.contains("polish.transport"))
        let buildRange = try XCTUnwrap(text.range(of: "\"appBuild\""))
        let versionRange = try XCTUnwrap(text.range(of: "\"appVersion\""))
        XCTAssertLessThan(buildRange.lowerBound, versionRange.lowerBound)
    }

    func testEveryStringFactoryRejectsCanaryAndSecretShapedInput() throws {
        let snapshot = DiagnosticsSnapshot(
            appVersion: "CANARY_TRANSCRIPT",
            appBuild: "CANARY_RESPONSE_BODY",
            operatingSystemVersion: "CANARY_PROMPT",
            architecture: .unknown,
            microphonePermission: .notDetermined,
            accessibilityPermission: .notDetermined,
            speechModelID: "https://host/CANARY_PROMPT",
            speechModelPhase: .failed,
            providerHost: "host/private?key=CANARY_KEY",
            providerModelID: "Bearer CANARY_KEY",
            historyEnabled: false,
            historyItemCount: -9,
            summary: SafeDiagnosticsSummary(
                lastStage: .failed,
                diagnosticCodes: [.polishInvalidResponse],
                eventCounts: []
            )
        )

        let text = try XCTUnwrap(String(
            data: DiagnosticsExporter().export(snapshot),
            encoding: .utf8
        ))
        for canary in [
            "CANARY_TRANSCRIPT", "CANARY_RESPONSE_BODY", "CANARY_PROMPT",
            "CANARY_KEY", "host/private", "Bearer"
        ] {
            XCTAssertFalse(text.contains(canary), "leaked \(canary)")
        }
        XCTAssertTrue(text.contains("redacted-invalid-build-value"))
        XCTAssertTrue(text.contains("redacted-invalid-model-id"))
        XCTAssertTrue(text.contains("redacted-invalid-host"))
        XCTAssertTrue(text.contains("\"historyItemCount\" : 0"))
    }

    func testModelIdentifierSanitizerRejectsURLPathCredentialEntropyAndLength() {
        let invalid = [
            "https://example.test/model",
            "org/model",
            "model?key=value",
            credentialSample("sk-", "proj-", "abcdefghijklmnopqrstuvwxyz0123456789"),
            "Bearer abcdefghijklmnopqrstuvwxyz0123456789",
            "aB3dE5fG7hI9jK1mN3pQ5rS7tU9vW1xY",
            "aB3d-E5fG-7hI9-jK1m-N3pQ-5rS7-tU9v-W1xY",
            credentialSample("AK", "IA", "0123456789ABCDEF"),
            credentialSample("github_", "pat_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"),
            credentialSample("gh", "p_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
            credentialSample("xox", "b-", "ABCDEFGHIJKLMN"),
            credentialSample("m-xox", "b-", "ABCDEFGHIJKLMN"),
            credentialSample("sk_", "live_", "abcdefghijklmnop"),
            credentialSample("AI", "za", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234"),
            credentialSample("sk-", "or-v1-", "abcdefghijklmnopqrstuvwxyz0123456789"),
            credentialSample("gsk", "_", "abcdefghijklmnopqrstuvwxyz0123456789"),
            credentialSample("hf", "_", "abcdefghijklmnopqrstuvwxyz0123456789"),
            credentialSample("xai", "-", "abcdefghijklmnopqrstuvwxyz0123456789"),
            "a-B-3-d-E-5-f-G-7-h-I-9-j-K-1-m-N-3-p-Q-5-r-S-7-t-U-9-v-W-1-x-Y",
            String(repeating: "a", count: 97),
            "line\nbreak"
        ]
        for value in invalid {
            XCTAssertEqual(
                DiagnosticValueSanitizer.modelIdentifier(value),
                "redacted-invalid-model-id",
                value
            )
        }
        XCTAssertEqual(DiagnosticValueSanitizer.modelIdentifier("gpt-4o-mini"), "gpt-4o-mini")
    }

    func testSafeLoggerHasOnlyClosedPublicLoggingMethodsAndStaticMessages() async throws {
        let logger = SafeLogger()
        for stage in PipelineStage.allDiagnosticCases {
            await logger.stageChanged(stage)
        }
        for component in DiagnosticComponent.allCases {
            for code in DiagnosticCode.allCases {
                await logger.serviceFailed(component: component, code: code)
            }
        }
        for phase in DiagnosticModelPhase.allCases {
            await logger.modelStateChanged(catalogIndex: 0, phase: phase)
        }
        let countBeforeRejectedIndexes = await logger.capturedMessages().count
        await logger.modelStateChanged(catalogIndex: -1, phase: .ready)
        await logger.modelStateChanged(catalogIndex: 256, phase: .ready)

        let messages = await logger.capturedMessages()
        XCTAssertEqual(messages.count, countBeforeRejectedIndexes)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty && $0.count < 96 })

        let source = try String(contentsOf: safeLoggerSourceURL(), encoding: .utf8)
        let declarations = source.matches(
            for: #"\bpublic(?:\s+(?:nonisolated|static|class))*\s+func\s+([A-Za-z0-9_]+)"#
        )
        XCTAssertEqual(Set(declarations), ["stageChanged", "serviceFailed", "modelStateChanged"])
        XCTAssertFalse(source.contains("public func log"))
        let methodInputs = source.matches(
            for: #"\bfunc\s+[A-Za-z0-9_]+\s*\(([^)]*)\)"#
        )
        for forbidden in ["String", "Error", "URL", "Data", "Any"] {
            XCTAssertFalse(
                methodInputs.contains { inputs in
                    inputs.containsMatch(for: #"\b"# + forbidden + #"\b"#)
                },
                "forbidden logger input \(forbidden)"
            )
        }
        XCTAssertFalse(source.contains(#"logger.notice("\("#))

        let exporterSource = try String(contentsOf: diagnosticsExporterSourceURL(), encoding: .utf8)
        XCTAssertTrue(exporterSource.contains("public struct DiagnosticsSnapshot: Encodable"))
        XCTAssertTrue(exporterSource.contains("public struct SafeDiagnosticsSummary: Encodable"))
        XCTAssertTrue(exporterSource.contains("public struct DiagnosticEventCount: Encodable"))
        XCTAssertFalse(exporterSource.contains("DiagnosticsSnapshot: Codable"))
    }

    func testSafeDiagnosticsSinkBoundsAndSanitizesCounters() async {
        let sink: any DiagnosticsSink = SafeDiagnosticsSink()
        for _ in 0..<10_025 {
            await sink.record(stage: .transcribing, code: .transcriptionFailed)
        }
        let concrete = sink as! SafeDiagnosticsSink
        await concrete.recordModelState(catalogIndex: 1, phase: .loading)
        await concrete.recordModelState(catalogIndex: -1, phase: .ready)
        let summary = await concrete.summary()

        XCTAssertEqual(summary.lastStage, .transcribing)
        XCTAssertEqual(summary.diagnosticCodes, [.transcriptionFailed])
        XCTAssertEqual(summary.eventCounts, [
            DiagnosticEventCount(component: .speechModel, count: 1),
            DiagnosticEventCount(component: .transcription, count: 10_000)
        ])
    }

    private func safeLoggerSourceURL() -> URL {
        sourceURL(relativePath: "Sources/UtterInkServices/Diagnostics/SafeLogger.swift")
    }

    private func diagnosticsExporterSourceURL() -> URL {
        sourceURL(relativePath: "Sources/UtterInkServices/Diagnostics/DiagnosticsExporter.swift")
    }

    private func sourceURL(relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func credentialSample(_ parts: String...) -> String {
        parts.joined()
    }
}

private extension PipelineStage {
    static let allDiagnosticCases: [PipelineStage] = [
        .idle, .requestingPermission, .recording, .stopping, .transcribing,
        .polishing, .delivering, .completed, .failed
    ]
}

private extension String {
    func matches(for pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return expression.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: self) else { return nil }
            return String(self[range])
        }
    }

    func containsMatch(for pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }
}
