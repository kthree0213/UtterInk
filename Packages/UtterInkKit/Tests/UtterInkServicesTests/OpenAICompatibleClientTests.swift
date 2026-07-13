import Foundation
import XCTest
import UtterInkCore
import UtterInkServices

final class OpenAICompatibleClientTests: XCTestCase {
    private let remoteURL = URL(string: "https://api.example.com/private/v1")!
    private let loopbackURL = URL(string: "http://localhost:11434/v1")!
    private let modelID = "model-exact"
    private let secretCanary = "SECRET-CANARY-DO-NOT-LEAK"
    private let transcriptCanary = "TRANSCRIPT-CANARY exact\nline"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testPublicInitializerConstructionSmoke() {
        let client: any PolishingService = OpenAICompatibleClient(clock: TestClientClock())
        XCTAssertNotNil(client)
    }

    func testPolishPostsBoundedExactJSONToPreservedBasePathWithAuthorization() async throws {
        let request = RequestRecorder()
        StubURLProtocol.install { protocolInstance in
            request.record(protocolInstance.request)
            protocolInstance.succeed(json: Self.chatResponse(" polished value "))
        }
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        let client = makeClient()

        let output = try await client.polish(
            rawText: transcriptCanary,
            snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
            token: token
        )

        XCTAssertEqual(output, "polished value")
        let captured = try XCTUnwrap(request.single)
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.url?.absoluteString, "https://api.example.com/private/v1/chat/completions")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer \(secretCanary)")
        XCTAssertFalse(captured.url?.absoluteString.contains(secretCanary) ?? true)
        let body = try XCTUnwrap(request.singleBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, modelID)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(
            messages,
            [
                ["role": "system", "content": "SYSTEM-INSTRUCTIONS exact"],
                ["role": "user", "content": transcriptCanary]
            ]
        )
    }

    func testLoopbackRevalidatesLocalhostUsesLiteralAndOmitsEmptyAuthorization() async throws {
        let resolver = SequencedResolver([
            ["127.0.0.1", "::1"],
            ["::1", "127.0.0.1"]
        ])
        let request = RequestRecorder()
        StubURLProtocol.install { protocolInstance in
            request.record(protocolInstance.request)
            protocolInstance.succeed(json: Self.chatResponse("ok"))
        }
        let empty = SessionSecret(utf8: "")
        defer { empty.clear() }
        let client = makeClient(resolver: resolver)

        let output = try await client.polish(
            rawText: "raw",
            snapshot: snapshot(baseURL: loopbackURL, policy: .loopbackHTTP, credential: empty),
            token: token
        )

        XCTAssertEqual(output, "ok")
        let captured = try XCTUnwrap(request.single)
        XCTAssertEqual(captured.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertNil(captured.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(resolver.hosts, ["localhost", "localhost"])
    }

    func testChangedLocalhostResolutionFailsBeforeDispatch() async {
        let resolver = SequencedResolver([
            ["127.0.0.1"],
            ["127.0.0.1", "::1"]
        ])
        let secret = SessionSecret(utf8: "loopback-secret")
        defer { secret.clear() }

        let code = await captureDiagnostic {
            try await makeClient(resolver: resolver).polish(
                rawText: transcriptCanary,
                snapshot: snapshot(baseURL: loopbackURL, policy: .loopbackHTTP, credential: secret),
                token: token
            )
        }

        XCTAssertEqual(code, .polishTransport)
        XCTAssertEqual(resolver.hosts, ["localhost", "localhost"])
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testEveryOperationUsesLockedDownFreshEphemeralConfiguration() async throws {
        let configurations = ConfigurationRecorder()
        StubURLProtocol.install { $0.succeed(json: Self.chatResponse("ok")) }
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let client = makeClient { configuration in
            configurations.record(configuration)
        }

        _ = try await client.polish(
            rawText: "raw",
            snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
            token: token
        )

        let config = try XCTUnwrap(configurations.single)
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertNil(config.urlCredentialStorage)
        XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertEqual(config.timeoutIntervalForResource, 30)
        XCTAssertEqual(config.httpMaximumConnectionsPerHost, 1)
        XCTAssertEqual(config.protocolClasses?.count, 1)
        XCTAssertTrue(config.protocolClasses?.first === StubURLProtocol.self)
    }

    func testSequentialOperationsUseDistinctFreshSessions() async throws {
        let configurations = ConfigurationRecorder()
        let sessionFactory = RecordingSessionFactory()
        StubURLProtocol.install { $0.succeed(json: Self.chatResponse("ok")) }
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let client = makeClient(
            configurationObserver: { configuration in
                configurations.record(configuration)
            },
            sessionFactory: sessionFactory
        )
        let currentSnapshot = snapshot(
            baseURL: remoteURL,
            policy: .remoteHTTPS,
            credential: secret
        )

        _ = try await client.polish(rawText: "one", snapshot: currentSnapshot, token: token)
        _ = try await client.polish(rawText: "two", snapshot: currentSnapshot, token: token)

        XCTAssertEqual(configurations.count, 2)
        let values = configurations.values
        XCTAssertFalse(values[0] === values[1])
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(sessionFactory.sessions.count, 2)
        XCTAssertEqual(sessionFactory.delegates.count, 2)
        XCTAssertFalse(sessionFactory.sessions[0] === sessionFactory.sessions[1])
        XCTAssertFalse(sessionFactory.delegates[0] === sessionFactory.delegates[1])
    }

    func testValidateGetsModelsAndRequiresExactModelID() async throws {
        let request = RequestRecorder()
        StubURLProtocol.install { protocolInstance in
            request.record(protocolInstance.request)
            protocolInstance.succeed(json: Data(#"{"data":[{"id":"model"},{"id":"model-exact"}]}"#.utf8))
        }
        let secret = SessionSecret(utf8: "validation-secret")
        defer { secret.clear() }
        let client = makeClient()
        let profile = ProviderProfile(
            id: UUID(),
            title: "Provider",
            baseURL: remoteURL,
            modelID: modelID,
            policy: .remoteHTTPS
        )

        let result = await client.validate(profile: profile, credential: secret)

        XCTAssertEqual(result, .ready(normalizedHost: "api.example.com", modelID: modelID))
        let captured = try XCTUnwrap(request.single)
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.url?.absoluteString, "https://api.example.com/private/v1/models")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer validation-secret")
        XCTAssertNil(captured.httpBody)
    }

    func testValidateLoopbackAllowsEmptyCredentialAndOmitsAuthorization() async {
        let resolver = SequencedResolver([["127.0.0.1"], ["127.0.0.1"]])
        let request = RequestRecorder()
        StubURLProtocol.install {
            request.record($0.request)
            $0.succeed(json: Data(#"{"data":[{"id":"model-exact"}]}"#.utf8))
        }
        let empty = SessionSecret(utf8: "")
        defer { empty.clear() }
        let profile = ProviderProfile(
            id: UUID(), title: "Local", baseURL: loopbackURL,
            modelID: modelID, policy: .loopbackHTTP
        )

        let result = await makeClient(resolver: resolver).validate(profile: profile, credential: empty)

        XCTAssertEqual(result, .ready(normalizedHost: "localhost:11434", modelID: modelID))
        XCTAssertNil(request.single?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.single?.url?.host, "127.0.0.1")
    }

    func testValidateRejectsModelSubstringAndMalformedModels() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let profile = ProviderProfile(
            id: UUID(), title: "Provider", baseURL: remoteURL,
            modelID: modelID, policy: .remoteHTTPS
        )

        for body in [
            Data(#"{"data":[{"id":"prefix-model-exact-suffix"}]}"#.utf8),
            Data(#"{"data":[{"id":7}]}"#.utf8),
            Data(#"{"data":"model-exact"}"#.utf8),
            Data("not-json".utf8)
        ] {
            StubURLProtocol.install { $0.succeed(json: body) }
            let result = await makeClient().validate(profile: profile, credential: secret)
            XCTAssertEqual(result, .failed(.polishInvalidResponse))
        }
    }

    func testRemoteCredentialMustBeNonemptyBeforeDispatch() async {
        let empty = SessionSecret(utf8: "")
        defer { empty.clear() }
        let client = makeClient()
        let polishError = await captureDiagnostic {
            try await client.polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: empty),
                token: token
            )
        }
        let profile = ProviderProfile(
            id: UUID(), title: "Provider", baseURL: remoteURL,
            modelID: modelID, policy: .remoteHTTPS
        )

        let validation = await client.validate(profile: profile, credential: empty)
        XCTAssertEqual(polishError, .credentialMissing)
        XCTAssertEqual(validation, .failed(.credentialMissing))
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testMissingProviderAndPolicyMismatchFailBeforeDispatch() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let client = makeClient()
        let missing = await captureDiagnostic {
            try await client.polish(rawText: "raw", snapshot: snapshot(provider: nil, credential: secret), token: token)
        }
        let mismatch = await captureDiagnostic {
            try await client.polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .loopbackHTTP, credential: secret),
                token: token
            )
        }

        XCTAssertEqual(missing, .polishTransport)
        XCTAssertEqual(mismatch, .polishTransport)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testHTTPStatusMappingIsClosedAndSanitized() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        for (status, expected) in [
            (401, DiagnosticCode.polishAuthentication),
            (403, .polishAuthentication),
            (429, .polishTransport),
            (500, .polishTransport),
            (599, .polishTransport),
            (302, .polishTransport)
        ] {
            StubURLProtocol.install {
                $0.respond(status: status, headers: [:], chunks: [Data("RESPONSE-CANARY".utf8)])
            }
            let error = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: transcriptCanary,
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }
            XCTAssertEqual(error, expected, "status \(status)")
        }
    }

    func testNetworkAndTimeoutFailuresMapToTransportWithoutLeakingDetails() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        for error in [
            URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "NETWORK-CANARY"]),
            URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "TIMEOUT-CANARY"])
        ] {
            StubURLProtocol.install { $0.fail(error) }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: transcriptCanary,
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }
            XCTAssertEqual(code, .polishTransport)
            assertSanitized(code, forbidden: [secretCanary, transcriptCanary, "NETWORK-CANARY", "TIMEOUT-CANARY"])
        }
    }

    func testRejectsDeclaredAndStreamedResponsesAboveTwoMiB() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let max = 2 * 1024 * 1024
        var mutableOversizedBody = Self.chatResponse("edge")
        mutableOversizedBody.append(
            Data(repeating: 0x20, count: max + 1 - mutableOversizedBody.count)
        )
        let oversizedValidBody = mutableOversizedBody
        StubURLProtocol.install {
            $0.respond(
                status: 200,
                headers: ["Content-Length": String(max + 1)],
                chunks: [oversizedValidBody]
            )
        }
        let declared = await captureDiagnostic {
            try await makeClient().polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
        }

        StubURLProtocol.install {
            $0.respondAndHold(
                status: 200,
                headers: ["Content-Length": "1"],
                chunks: [
                    Data(oversizedValidBody.prefix(max)),
                    Data(oversizedValidBody.suffix(1))
                ]
            )
        }
        let streamed = await captureDiagnostic {
            try await makeClient().polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
        }

        XCTAssertEqual(declared, .polishInvalidResponse)
        XCTAssertEqual(streamed, .polishInvalidResponse)
        await waitForProtocolStop()
    }

    func testAcceptsAValidResponseWhoseTotalBytesEqualTwoMiB() async throws {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let max = 2 * 1024 * 1024
        var body = Self.chatResponse("edge")
        body.append(Data(repeating: 0x20, count: max - body.count))
        XCTAssertEqual(body.count, max)
        let firstHalf = Data(body.prefix(max / 2))
        let secondHalf = Data(body.suffix(max / 2))
        StubURLProtocol.install {
            $0.respond(status: 200, headers: [:], chunks: [firstHalf, secondHalf])
        }

        let result = try await makeClient().polish(
            rawText: "raw",
            snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
            token: token
        )

        XCTAssertEqual(result, "edge")
    }

    func testRejectsEncodedRequestBodyAboveTwoMiBBeforeDispatch() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let error = await captureDiagnostic {
            try await makeClient().polish(
                rawText: String(repeating: "x", count: 2 * 1024 * 1024),
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
        }

        XCTAssertEqual(error, .polishInvalidResponse)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testDecodesStringAndOnlyExplicitTextPartContent() async throws {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let cases: [(Data, String)] = [
            (Self.chatResponse("string content"), "string content"),
            (Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"part one"},{"type":"text","text":" + part two"}]}}]}"#.utf8), "part one + part two")
        ]
        for (body, expected) in cases {
            StubURLProtocol.install { $0.succeed(json: body) }
            let output = try await makeClient().polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
            XCTAssertEqual(output, expected)
        }

        for body in [
            Data(#"{"choices":[{"message":{"content":[{"type":"image","text":"forbidden"}]}}]}"#.utf8),
            Data(#"{"choices":[{"message":{"content":[{"type":"text","text":9}]}}]}"#.utf8),
            Data(#"{"choices":[{"message":{"content":9}}]}"#.utf8)
        ] {
            StubURLProtocol.install { $0.succeed(json: body) }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: "raw",
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }
            XCTAssertEqual(code, .polishInvalidResponse)
        }
    }

    func testStripsCompleteOuterFenceAndKnownReasoningBlocksWithoutExposure() async throws {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let cases: [(String, String)] = [
            ("```markdown\nfinal text\n```", "final text"),
            ("<think>HIDDEN-CANARY</think> visible", "visible"),
            ("before <analysis>HIDDEN-CANARY</analysis> after", "before  after"),
            ("<REASONING>HIDDEN-CANARY</REASONING>\nanswer", "answer")
        ]
        for (content, expected) in cases {
            StubURLProtocol.install { $0.succeed(json: Self.chatResponse(content)) }
            let output = try await makeClient().polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
            XCTAssertEqual(output, expected)
            XCTAssertFalse(output.contains("HIDDEN-CANARY"))
        }
    }

    func testStripsMatchingFourOrMoreCharacterOuterFences() async throws {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let cases: [(String, String)] = [
            ("````markdown\nfour-backtick result\n````", "four-backtick result"),
            ("~~~~text\nfour-tilde result\n~~~~", "four-tilde result"),
            ("`````\nfive-backtick result\n`````", "five-backtick result")
        ]
        for (content, expected) in cases {
            StubURLProtocol.install { $0.succeed(json: Self.chatResponse(content)) }
            let output = try await makeClient().polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
            XCTAssertEqual(output, expected)
        }
    }

    func testRejectsMalformedEmptyStructuredAndResidualReasoningOutput() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let bodies = [
            Data("not-json".utf8),
            Data(#"{"choices":[]}"#.utf8),
            Self.chatResponse("   \n"),
            Self.chatResponse("{}"),
            Self.chatResponse("[\"not text\"]"),
            Self.chatResponse("```\n```"),
            Self.chatResponse("~~~\n~~~"),
            Self.chatResponse("<think>unclosed"),
            Self.chatResponse("residual </analysis>"),
            Self.chatResponse("<reasoning>only hidden</reasoning>")
        ]
        for body in bodies {
            StubURLProtocol.install { $0.succeed(json: body) }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: transcriptCanary,
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }
            XCTAssertEqual(code, .polishInvalidResponse)
        }
    }

    func testCleanupCannotExposeFencedJSONAfterRemovingReasoningAndUsesOnlyChoiceZero() async {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let bodies = [
            Self.chatResponse("<think>hidden</think>\n```json\n{}\n```"),
            Data(#"{"choices":[{"message":{"content":"   "}},{"message":{"content":"must-not-select"}}]}"#.utf8)
        ]
        for body in bodies {
            StubURLProtocol.install { $0.succeed(json: body) }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: "raw",
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }
            XCTAssertEqual(code, .polishInvalidResponse)
        }
    }

    func testValidChoiceZeroIgnoresMalformedUnusedLaterChoice() async throws {
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let body = Data(
            #"{"choices":[{"message":{"content":"selected result"}},{"message":{"content":9}}]}"#.utf8
        )
        StubURLProtocol.install { $0.succeed(json: body) }

        let output = try await makeClient().polish(
            rawText: "raw",
            snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
            token: token
        )

        XCTAssertEqual(output, "selected result")
    }

    func testRedirectPolicyAllowsOnlySameOriginHTTPSAndNeverForwardsRejectedAuthorization() throws {
        var original = URLRequest(url: URL(string: "https://api.example.com:443/v1/chat/completions")!)
        original.setValue("Bearer \(secretCanary)", forHTTPHeaderField: "Authorization")
        let allowedURL = URL(string: "https://api.example.com/redirected")!
        let allowed = try XCTUnwrap(SecureRedirectDelegate.redirectedRequest(
            from: original,
            to: URLRequest(url: allowedURL)
        ))
        XCTAssertEqual(allowed.url, allowedURL)
        XCTAssertEqual(allowed.value(forHTTPHeaderField: "Authorization"), "Bearer \(secretCanary)")

        let rejected = [
            "https://other.example.com/redirected",
            "http://api.example.com/redirected",
            "https://user@api.example.com/redirected",
            "https://api.example.com/redirected?query=1",
            "https://api.example.com/redirected#fragment",
            "https://api.example.com:8443/redirected"
        ]
        for target in rejected {
            var proposed = URLRequest(url: URL(string: target)!)
            proposed.setValue("Bearer \(secretCanary)", forHTTPHeaderField: "Authorization")
            XCTAssertNil(SecureRedirectDelegate.redirectedRequest(from: original, to: proposed), target)
        }

        var httpOriginal = URLRequest(url: URL(string: "http://127.0.0.1:11434/v1")!)
        httpOriginal.setValue("Bearer \(secretCanary)", forHTTPHeaderField: "Authorization")
        let httpProposed = URLRequest(url: URL(string: "http://127.0.0.1:11434/next")!)
        XCTAssertNil(SecureRedirectDelegate.redirectedRequest(from: httpOriginal, to: httpProposed))
    }

    func testRedirectPolicyRejectsMalformedExplicitPortsWithoutRestoringAuthorization() throws {
        var original = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        original.setValue("Bearer \(secretCanary)", forHTTPHeaderField: "Authorization")

        for target in [
            "https://api.example.com:/redirected",
            "https://api.example.com:999999999999999999999/redirected"
        ] {
            let url = try XCTUnwrap(URL(string: target))
            var proposed = URLRequest(url: url)
            proposed.setValue("Bearer PROPOSED-CANARY", forHTTPHeaderField: "Authorization")

            XCTAssertNil(
                SecureRedirectDelegate.redirectedRequest(from: original, to: proposed),
                target
            )
        }
    }

    func testTransportRejectsMalformedExplicitPortRedirectsBeforeSecondRequest() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }

        for target in [
            "https://api.example.com:/redirected",
            "https://api.example.com:999999999999999999999/redirected"
        ] {
            let url = URL(string: target)!
            StubURLProtocol.install {
                $0.redirect(to: url, strippingAuthorization: false)
            }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: transcriptCanary,
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }

            XCTAssertEqual(code, .polishTransport, target)
            XCTAssertEqual(StubURLProtocol.requestCount, 1, target)
            assertSanitized(code, forbidden: [target, secretCanary, transcriptCanary])
        }
    }

    func testTransportActuallyFollowsSameOriginHTTPSRedirectWithAuthorization() async throws {
        let secondRequest = RequestRecorder()
        StubURLProtocol.install { protocolInstance in
            if protocolInstance.request.url?.path == "/private/v1/chat/completions" {
                protocolInstance.redirect(
                    to: URL(string: "https://api.example.com/redirected")!,
                    strippingAuthorization: true
                )
            } else {
                secondRequest.record(protocolInstance.request)
                protocolInstance.succeed(json: Self.chatResponse("redirected result"))
            }
        }
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }

        let output = try await makeClient().polish(
            rawText: "raw",
            snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
            token: token
        )

        XCTAssertEqual(output, "redirected result")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
        XCTAssertEqual(secondRequest.single?.url?.absoluteString, "https://api.example.com/redirected")
        XCTAssertEqual(
            secondRequest.single?.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(secretCanary)"
        )
    }

    func testTransportRejectsCrossOriginAndDowngradeRedirectsBeforeSecondRequest() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        for target in [
            "https://other.example.com/redirected",
            "http://api.example.com/redirected"
        ] {
            StubURLProtocol.install {
                $0.redirect(to: URL(string: target)!, strippingAuthorization: false)
            }
            let code = await captureDiagnostic {
                try await makeClient().polish(
                    rawText: transcriptCanary,
                    snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                    token: token
                )
            }

            XCTAssertEqual(code, .polishTransport, target)
            XCTAssertEqual(StubURLProtocol.requestCount, 1, target)
            assertSanitized(code, forbidden: [target, secretCanary, transcriptCanary])
        }
    }

    func testValidateMapsAuthRejectsRedirectAndActivelyCancelsOversize() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        let profile = ProviderProfile(
            id: UUID(), title: "Provider", baseURL: remoteURL,
            modelID: modelID, policy: .remoteHTTPS
        )

        for status in [401, 403] {
            StubURLProtocol.install {
                $0.respond(status: status, headers: [:], chunks: [])
            }
            let result = await makeClient().validate(profile: profile, credential: secret)
            XCTAssertEqual(result, .failed(.polishAuthentication))
        }

        StubURLProtocol.install {
            $0.redirect(
                to: URL(string: "https://redirect-canary.example/models")!,
                strippingAuthorization: false
            )
        }
        let redirect = await makeClient().validate(profile: profile, credential: secret)
        XCTAssertEqual(redirect, .failed(.polishTransport))
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        let max = 2 * 1024 * 1024
        var mutableOversizedModels = Data(#"{"data":[{"id":"model-exact"}]}"#.utf8)
        mutableOversizedModels.append(
            Data(repeating: 0x20, count: max + 1 - mutableOversizedModels.count)
        )
        let oversizedModels = mutableOversizedModels
        StubURLProtocol.install {
            $0.respondAndHold(
                status: 200,
                headers: ["Content-Length": "1"],
                chunks: [
                    Data(oversizedModels.prefix(max)),
                    Data(oversizedModels.suffix(1))
                ]
            )
        }
        let oversized = await makeClient().validate(profile: profile, credential: secret)
        XCTAssertEqual(oversized, .failed(.polishInvalidResponse))
        await waitForProtocolStop()
    }

    func testValidateMapsRateLimitServerNetworkAndTimeoutToTransport() async {
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        let profile = ProviderProfile(
            id: UUID(), title: "Provider", baseURL: remoteURL,
            modelID: modelID, policy: .remoteHTTPS
        )

        for status in [429, 500, 503] {
            StubURLProtocol.install {
                $0.respond(
                    status: status,
                    headers: [:],
                    chunks: [Data("VALIDATE-RESPONSE-CANARY".utf8)]
                )
            }
            let result = await makeClient().validate(profile: profile, credential: secret)
            XCTAssertEqual(result, .failed(.polishTransport), "status \(status)")
        }

        for error in [
            URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "NETWORK-CANARY"]),
            URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "TIMEOUT-CANARY"])
        ] {
            StubURLProtocol.install { $0.fail(error) }
            let result = await makeClient().validate(profile: profile, credential: secret)
            XCTAssertEqual(result, .failed(.polishTransport))
            let rendered = String(describing: result) + String(reflecting: result)
            for canary in [secretCanary, "NETWORK-CANARY", "TIMEOUT-CANARY"] {
                XCTAssertFalse(rendered.contains(canary))
            }
        }
    }

    func testTaskCancellationCancelsTheOnlyRequestAndThrowsCancelledCode() async {
        let started = expectation(description: "request started")
        StubURLProtocol.install { _ in started.fulfill() }
        let secret = SessionSecret(utf8: "secret")
        defer { secret.clear() }
        let client = makeClient()
        let task = Task {
            try await client.polish(
                rawText: "raw",
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let code as DiagnosticCode {
            XCTAssertEqual(code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await waitForProtocolStop()
    }

    func testEveryFailureRenderingExcludesCredentialTranscriptPathAndResponseCanaries() async {
        StubURLProtocol.install {
            $0.respond(status: 500, headers: [:], chunks: [Data("RESPONSE-BODY-CANARY".utf8)])
        }
        let secret = SessionSecret(utf8: secretCanary)
        defer { secret.clear() }
        let code = await captureDiagnostic {
            try await makeClient().polish(
                rawText: transcriptCanary,
                snapshot: snapshot(baseURL: remoteURL, policy: .remoteHTTPS, credential: secret),
                token: token
            )
        }

        XCTAssertEqual(code, .polishTransport)
        assertSanitized(
            code,
            forbidden: [secretCanary, transcriptCanary, "private/v1", "RESPONSE-BODY-CANARY", remoteURL.absoluteString]
        )
    }

    private var token: EffectToken {
        EffectToken(sessionID: SessionID(), generation: 7)
    }

    private func makeClient(
        resolver: any HostResolver = FixedResolver([]),
        configurationObserver: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in },
        sessionFactory: any URLSessionCreating = SystemURLSessionFactory()
    ) -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            clock: TestClientClock(),
            resolver: resolver,
            protocolClasses: [StubURLProtocol.self],
            configurationObserver: configurationObserver,
            sessionFactory: sessionFactory
        )
    }

    private func snapshot(
        provider: ProviderSelection? = nil,
        baseURL: URL? = nil,
        policy: EndpointPolicy = .remoteHTTPS,
        credential: SessionSecret?
    ) -> SessionSnapshot {
        let selected = provider ?? baseURL.map {
            ProviderSelection(profileID: UUID(), baseURL: $0, modelID: modelID, policy: policy)
        }
        return SessionSnapshot(
            id: SessionID(),
            target: .copyOnly,
            recognition: .automatic,
            speechModelID: "small",
            outputMode: OutputMode(
                id: UUID(),
                title: "Polish",
                skipsPolishing: false,
                instructions: "SYSTEM-INSTRUCTIONS exact"
            ),
            provider: selected,
            historyGeneration: 1,
            historyEnabled: true,
            deliveryPreference: .copyOnly,
            credential: credential
        )
    }

    private static func chatResponse(_ content: String) -> Data {
        let object: [String: Any] = [
            "choices": [["message": ["content": content]]]
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func captureDiagnostic(
        _ operation: () async throws -> String
    ) async -> DiagnosticCode? {
        do {
            _ = try await operation()
            return nil
        } catch let code as DiagnosticCode {
            return code
        } catch {
            XCTFail("Unexpected non-diagnostic error: \(error)")
            return nil
        }
    }

    private func assertSanitized(
        _ code: DiagnosticCode?,
        forbidden: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = [
            String(describing: code as Any),
            String(reflecting: code as Any)
        ].joined(separator: " ")
        for canary in forbidden {
            XCTAssertFalse(rendered.contains(canary), "leaked \(canary)", file: file, line: line)
        }
    }

    private func waitForProtocolStop(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 where StubURLProtocol.stopCount == 0 {
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(StubURLProtocol.stopCount, 1, file: file, line: line)
    }
}

private struct TestClientClock: AppClock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
    }
}

private struct FixedResolver: HostResolver {
    let answers: [String]

    init(_ answers: [String]) {
        self.answers = answers
    }

    func resolve(_ host: String) throws -> [String] {
        answers
    }
}

private final class SequencedResolver: HostResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]]
    private var recordedHosts: [String] = []

    init(_ answers: [[String]]) {
        self.answers = answers
    }

    var hosts: [String] {
        lock.withLock { recordedHosts }
    }

    func resolve(_ host: String) throws -> [String] {
        lock.withLock {
            recordedHosts.append(host)
            guard !answers.isEmpty else { return [] }
            return answers.removeFirst()
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var bodies: [Data?] = []

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        lock.withLock {
            requests.append(request)
            bodies.append(body)
        }
    }

    var single: URLRequest? {
        lock.withLock { requests.count == 1 ? requests[0] : nil }
    }

    var singleBody: Data? {
        lock.withLock { bodies.count == 1 ? bodies[0] : nil }
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class ConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configurations: [URLSessionConfiguration] = []

    func record(_ configuration: URLSessionConfiguration) {
        lock.withLock { configurations.append(configuration) }
    }

    var single: URLSessionConfiguration? {
        lock.withLock { configurations.count == 1 ? configurations[0] : nil }
    }

    var count: Int {
        lock.withLock { configurations.count }
    }

    var values: [URLSessionConfiguration] {
        lock.withLock { configurations }
    }
}

private final class RecordingSessionFactory: URLSessionCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessions: [URLSession] = []
    private var storedDelegates: [BoundedSessionDelegate] = []

    var sessions: [URLSession] {
        lock.withLock { storedSessions }
    }

    var delegates: [BoundedSessionDelegate] {
        lock.withLock { storedDelegates }
    }

    func makeSession(
        configuration: URLSessionConfiguration,
        delegate: BoundedSessionDelegate
    ) -> URLSession {
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        lock.withLock {
            storedSessions.append(session)
            storedDelegates.append(delegate)
        }
        return session
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (StubURLProtocol) -> Void

    private static let stateLock = NSLock()
    private static var handler: Handler?
    private static var requests = 0
    private static var stops = 0

    static var requestCount: Int {
        stateLock.withLock { requests }
    }

    static var stopCount: Int {
        stateLock.withLock { stops }
    }

    static func install(_ handler: @escaping Handler) {
        stateLock.withLock {
            self.handler = handler
            requests = 0
            stops = 0
        }
    }

    static func reset() {
        stateLock.withLock {
            handler = nil
            requests = 0
            stops = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.stateLock.withLock { () -> Handler? in
            Self.requests += 1
            return Self.handler
        }
        guard let current else {
            fail(URLError(.unsupportedURL))
            return
        }
        current(self)
    }

    override func stopLoading() {
        Self.stateLock.withLock { Self.stops += 1 }
    }

    func succeed(json: Data) {
        respond(status: 200, headers: ["Content-Type": "application/json"], chunks: [json])
    }

    func respond(status: Int, headers: [String: String], chunks: [Data]) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
              ) else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    func respondAndHold(status: Int, headers: [String: String], chunks: [Data]) {
        guard let response = makeResponse(status: status, headers: headers) else {
            fail(URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
    }

    func redirect(to url: URL, strippingAuthorization: Bool) {
        guard let response = makeResponse(
            status: 307,
            headers: ["Location": url.absoluteString]
        ) else {
            fail(URLError(.badServerResponse))
            return
        }
        var redirected = request
        redirected.url = url
        if strippingAuthorization {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    private func makeResponse(
        status: Int,
        headers: [String: String]
    ) -> HTTPURLResponse? {
        guard let url = request.url else { return nil }
        return HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}
