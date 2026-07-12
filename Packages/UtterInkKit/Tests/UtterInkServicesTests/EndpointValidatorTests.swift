import Foundation
import XCTest
import UtterInkCore
import UtterInkServices

final class EndpointValidatorTests: XCTestCase {
    func testAcceptsHTTPSAndCanonicalLoopbackHTTPMatrix() throws {
        let cases: [(input: String, expectedURL: String, policy: EndpointPolicy)] = [
            ("https://api.example.com/v1", "https://api.example.com/v1", .remoteHTTPS),
            ("https://api.example.com:8443/v1", "https://api.example.com:8443/v1", .remoteHTTPS),
            ("http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1", .loopbackHTTP),
            ("http://127.255.255.255/v1", "http://127.255.255.255/v1", .loopbackHTTP),
            ("http://[::1]:11434/v1", "http://[::1]:11434/v1", .loopbackHTTP)
        ]

        for item in cases {
            let endpoint = try EndpointValidator.validate(item.input, resolver: FakeHostResolver([]))
            XCTAssertEqual(endpoint.requestBaseURL.absoluteString, item.expectedURL, item.input)
            XCTAssertEqual(endpoint.policy, item.policy, item.input)
        }
    }

    func testRejectsNonNetworkAndNonAbsoluteURLs() {
        assertRejected([
            "",
            "example.com/v1",
            "/v1",
            "//example.com/v1",
            "http:localhost/v1",
            "https:example.com/v1",
            "http:///v1",
            "file:///tmp/provider",
            "ftp://example.com/v1",
            "mailto:user@example.com"
        ])
    }

    func testRejectsUserInfoQueryAndFragment() {
        let credentialURL = "https://user:" + "pass@example.com/v1"
        assertRejected([
            "https://user@example.com/v1",
            credentialURL,
            "https://example.com/v1?key=value",
            "https://example.com/v1?",
            "https://example.com/v1#fragment",
            "https://example.com/v1#"
        ])
    }

    func testRejectsAuthorityConfusionAndEncodedHostDelimiters() {
        let portUserInfo = "https://example.com:" + "443@evil.example/v1"
        assertRejected([
            "https://example.com\\@evil.example/v1",
            "https://example.com%2fevil.example/v1",
            "https://example.com%5cevil.example/v1",
            portUserInfo
        ])
    }

    func testRejectsInvalidAndOutOfRangePorts() {
        assertRejected([
            "https://example.com:0/v1",
            "https://example.com:65536/v1",
            "https://example.com:-1/v1",
            "https://example.com:not-a-port/v1",
            "http://127.0.0.1:99999/v1"
        ])
    }

    func testRejectsLiteralAndPercentEncodedControlCharacters() {
        assertRejected([
            "https://example.com/v1\nleak",
            "https://example.com/v1\tleak",
            "https://example.com/v1/%00",
            "https://example.com/v1/%0A",
            "https://example.com/v1/%7F"
        ])
    }

    func testPreservesBasePathAndRemovesOnlyRedundantTrailingSlashes() throws {
        let cases: [(String, String)] = [
            ("https://example.com", "https://example.com/"),
            ("https://example.com/", "https://example.com/"),
            ("https://example.com///", "https://example.com/"),
            ("https://example.com/v1", "https://example.com/v1"),
            ("https://example.com/v1/", "https://example.com/v1"),
            ("https://example.com/v1///", "https://example.com/v1"),
            ("https://example.com/router/openai/v1//", "https://example.com/router/openai/v1")
        ]

        for (input, expected) in cases {
            let endpoint = try EndpointValidator.validate(input, resolver: FakeHostResolver([]))
            XCTAssertEqual(endpoint.requestBaseURL.absoluteString, expected, input)
        }
    }

    func testRejectsPublicAndLANPlainHTTP() {
        assertRejected([
            "http://api.example.com/v1",
            "http://192.168.1.2:11434/v1",
            "http://10.0.0.1/v1",
            "http://169.254.1.1/v1",
            "http://8.8.8.8/v1",
            "http://[fe80::1]/v1",
            "http://[2001:db8::1]/v1"
        ])
    }

    func testRejectsNoncanonicalLocalhostAndIPv4Aliases() {
        assertRejected([
            "http://LOCALHOST:11434/v1",
            "http://LocalHost:11434/v1",
            "http://localhost.:11434/v1",
            "http://2130706433/v1",
            "http://0x7f000001/v1",
            "http://017700000001/v1",
            "http://127.1/v1",
            "http://127.0.1/v1",
            "http://127.00.0.1/v1",
            "http://127.0.0.01/v1",
            "http://127.0.0.1./v1",
            "http://127.0.0.256/v1",
            "http://128.0.0.1/v1"
        ])
    }

    func testRejectsMappedZonedAndOtherIPv6OverHTTP() {
        assertRejected([
            "http://[::ffff:127.0.0.1]/v1",
            "http://[::ffff:7f00:1]/v1",
            "http://[::ffff:192.168.1.2]/v1",
            "http://[0:0:0:0:0:0:0:1]/v1",
            "http://[::2]/v1",
            "http://[fe80::1%25lo0]/v1"
        ])
    }

    func testLocalhostRequiresOnlyCanonicalLoopbackAnswersAndPrefersExact127001() throws {
        let endpoint = try EndpointValidator.validate(
            "http://localhost:11434/v1/",
            resolver: FakeHostResolver(["::1", "127.0.0.2", "127.0.0.1"])
        )

        XCTAssertEqual(endpoint.requestBaseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(endpoint.displayAuthority, "localhost:11434")
        XCTAssertEqual(endpoint.policy, .loopbackHTTP)
    }

    func testLocalhostUsesIPv6LiteralWhenItIsTheOnlyAnswer() throws {
        let endpoint = try EndpointValidator.validate(
            "http://localhost:11434/v1",
            resolver: FakeHostResolver(["::1"])
        )

        XCTAssertEqual(endpoint.requestBaseURL.absoluteString, "http://[::1]:11434/v1")
        XCTAssertEqual(endpoint.displayAuthority, "localhost:11434")
    }

    func testLocalhostRejectsEmptyMixedMappedAndNoncanonicalResolverAnswers() {
        let invalidAnswers = [
            [],
            ["127.0.0.1", "192.168.1.2"],
            ["127.0.0.1", "::ffff:127.0.0.1"],
            ["::1", "::ffff:192.168.1.2"],
            ["127.00.0.1"],
            ["0:0:0:0:0:0:0:1"],
            ["localhost"]
        ]

        for answers in invalidAnswers {
            XCTAssertThrowsError(
                try EndpointValidator.validate(
                    "http://localhost:11434/v1",
                    resolver: FakeHostResolver(answers)
                ),
                "unexpectedly accepted resolver answers: \(answers)"
            )
        }
    }

    func testImmediateRevalidationRequiresOriginalLiteralAndAllLoopbackAnswers() throws {
        let endpoint = try EndpointValidator.validate(
            "http://localhost:11434/v1",
            resolver: FakeHostResolver(["127.0.0.1", "::1"])
        )

        XCTAssertNoThrow(
            try EndpointValidator.revalidate(
                endpoint,
                resolver: FakeHostResolver(["::1", "127.0.0.1"])
            )
        )
        XCTAssertThrowsError(
            try EndpointValidator.revalidate(endpoint, resolver: FakeHostResolver([]))
        )
        XCTAssertThrowsError(
            try EndpointValidator.revalidate(endpoint, resolver: FakeHostResolver(["::1"]))
        )
        let singleAnswerEndpoint = try EndpointValidator.validate(
            "http://localhost:11434/v1",
            resolver: FakeHostResolver(["127.0.0.1"])
        )
        XCTAssertThrowsError(
            try EndpointValidator.revalidate(
                singleAnswerEndpoint,
                resolver: FakeHostResolver(["127.0.0.1", "::1"])
            )
        )
        XCTAssertThrowsError(
            try EndpointValidator.revalidate(
                endpoint,
                resolver: FakeHostResolver(["127.0.0.1", "192.168.1.2"])
            )
        )
        XCTAssertEqual(endpoint.requestBaseURL.absoluteString, "http://127.0.0.1:11434/v1")
    }

    func testDirectLiteralRevalidationDoesNotConsultDNS() throws {
        let resolver = RecordingHostResolver(answer: ["192.168.1.2"])
        let endpoint = try EndpointValidator.validate(
            "http://127.0.0.1:11434/v1",
            resolver: resolver
        )

        try EndpointValidator.revalidate(endpoint, resolver: resolver)
        XCTAssertEqual(resolver.hosts, [])
    }

    func testRemoteHTTPSNeverConsultsResolver() throws {
        let resolver = RecordingHostResolver(answer: ["192.168.1.2"])

        let endpoint = try EndpointValidator.validate(
            "https://api.example.com/private/v1",
            requiring: .remoteHTTPS,
            resolver: resolver
        )
        try EndpointValidator.revalidate(endpoint, resolver: resolver)

        XCTAssertEqual(resolver.hosts, [])
        XCTAssertEqual(endpoint.displayAuthority, "api.example.com")
    }

    func testThrowingResolverFailureIsSanitized() {
        XCTAssertThrowsError(
            try EndpointValidator.validate(
                "http://localhost:11434/v1",
                resolver: ThrowingHostResolver()
            )
        ) { error in
            let rendered = [
                String(describing: error),
                String(reflecting: error),
                error.localizedDescription
            ].joined(separator: " ")
            XCTAssertFalse(rendered.contains("RESOLVER-CANARY"))
            XCTAssertFalse(rendered.contains("localhost:11434"))
        }
    }

    func testDisplayAuthorityContainsOnlyOriginalHostAndExplicitPort() throws {
        let cases: [(input: String, display: String)] = [
            ("https://api.example.com/private/v1", "api.example.com"),
            ("https://api.example.com:443/private/v1", "api.example.com:443"),
            ("https://api.example.com:8443/private/v1", "api.example.com:8443"),
            ("http://127.0.0.1:80/private/v1", "127.0.0.1:80"),
            ("http://[::1]:11434/private/v1", "[::1]:11434")
        ]

        for item in cases {
            let endpoint = try EndpointValidator.validate(item.input, resolver: FakeHostResolver([]))
            XCTAssertEqual(endpoint.displayAuthority, item.display, item.input)
            XCTAssertFalse(endpoint.displayAuthority.contains("private"), item.input)
            XCTAssertFalse(endpoint.displayAuthority.contains("?"), item.input)
            XCTAssertFalse(endpoint.displayAuthority.contains("#"), item.input)
            XCTAssertFalse(endpoint.displayAuthority.contains("@"), item.input)
        }
    }

    func testRequiredPolicyMustAgreeExactly() throws {
        XCTAssertNoThrow(
            try EndpointValidator.validate(
                "https://api.example.com/v1",
                requiring: .remoteHTTPS,
                resolver: FakeHostResolver([])
            )
        )
        XCTAssertNoThrow(
            try EndpointValidator.validate(
                "http://127.0.0.1:11434/v1",
                requiring: .loopbackHTTP,
                resolver: FakeHostResolver([])
            )
        )
        XCTAssertThrowsError(
            try EndpointValidator.validate(
                "https://api.example.com/v1",
                requiring: .loopbackHTTP,
                resolver: FakeHostResolver([])
            )
        )
        XCTAssertThrowsError(
            try EndpointValidator.validate(
                "http://127.0.0.1:11434/v1",
                requiring: .remoteHTTPS,
                resolver: FakeHostResolver([])
            )
        )
    }

    func testValidationErrorsAreSanitizedAndNeverContainRawInput() {
        let credentialCanary = "https://user:" + "SECRET-CANARY@example.com/v1"
        let canaries = [
            credentialCanary,
            "https://example.com/private/path?token=SECRET-CANARY",
            "http://192.168.1.2/SECRET-CANARY"
        ]

        for input in canaries {
            XCTAssertThrowsError(
                try EndpointValidator.validate(input, resolver: FakeHostResolver([]))
            ) { error in
                let rendered = String(describing: error) + String(reflecting: error)
                XCTAssertFalse(rendered.contains(input))
                XCTAssertFalse(rendered.contains("SECRET-CANARY"))
                XCTAssertFalse(rendered.contains("private/path"))
            }
        }
    }

    private func assertRejected(
        _ values: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for value in values {
            XCTAssertThrowsError(
                try EndpointValidator.validate(value, resolver: FakeHostResolver([])),
                "unexpectedly accepted \(value)",
                file: file,
                line: line
            )
        }
    }
}

private struct FakeHostResolver: HostResolver {
    let answers: [String]

    init(_ answers: [String]) {
        self.answers = answers
    }

    func resolve(_ host: String) throws -> [String] {
        answers
    }
}

private final class RecordingHostResolver: HostResolver, @unchecked Sendable {
    private(set) var hosts: [String] = []
    private let answer: [String]

    init(answer: [String]) {
        self.answer = answer
    }

    func resolve(_ host: String) throws -> [String] {
        hosts.append(host)
        return answer
    }
}

private struct ThrowingHostResolver: HostResolver {
    struct ResolverError: Error, CustomStringConvertible {
        let description = "RESOLVER-CANARY"
    }

    func resolve(_ host: String) throws -> [String] {
        throw ResolverError()
    }
}
