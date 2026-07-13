import Foundation
import UtterInkCore

public actor OpenAICompatibleClient: PolishingService, ProviderValidationService {
    private static let byteLimit = 2 * 1024 * 1024

    private let clock: any AppClock
    private let resolver: any HostResolver
    private let protocolClasses: [AnyClass]
    private let configurationObserver: @Sendable (URLSessionConfiguration) -> Void
    private let sessionFactory: any URLSessionCreating

    public init(clock: any AppClock) {
        self.clock = clock
        resolver = SystemHostResolver()
        protocolClasses = []
        configurationObserver = { _ in }
        sessionFactory = SystemURLSessionFactory()
    }

    package init(
        clock: any AppClock,
        resolver: any HostResolver,
        protocolClasses: [AnyClass],
        configurationObserver: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in },
        sessionFactory: any URLSessionCreating = SystemURLSessionFactory()
    ) {
        self.clock = clock
        self.resolver = resolver
        self.protocolClasses = protocolClasses
        self.configurationObserver = configurationObserver
        self.sessionFactory = sessionFactory
    }

    public func polish(
        rawText: String,
        snapshot: SessionSnapshot,
        token: EffectToken
    ) async throws -> String {
        do {
            try Task.checkCancellation()
            guard let provider = snapshot.provider else {
                throw DiagnosticCode.polishTransport
            }
            let endpoint = try validatedEndpoint(
                provider.baseURL,
                requiring: provider.policy
            )
            guard !provider.modelID.isEmpty else {
                throw DiagnosticCode.polishTransport
            }
            let credential = credentialValue(snapshot.credential)
            if endpoint.policy == .remoteHTTPS, credential.isEmpty {
                throw DiagnosticCode.credentialMissing
            }

            let requestBody = try JSONEncoder().encode(
                ChatRequest(
                    model: provider.modelID,
                    messages: [
                        Message(role: "system", content: snapshot.outputMode.instructions),
                        Message(role: "user", content: rawText)
                    ]
                )
            )
            guard requestBody.count <= Self.byteLimit else {
                throw DiagnosticCode.polishInvalidResponse
            }
            let url = try apiURL(endpoint.requestBaseURL, suffix: "chat/completions")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !credential.isEmpty {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }

            let response = try await transport(request)
            guard (200...299).contains(response.statusCode) else {
                throw statusCode(response.statusCode)
            }
            return try cleanedContent(from: response.body)
        } catch let code as DiagnosticCode {
            throw code
        } catch let failure as TransportFailure {
            switch failure {
            case .cancelled:
                throw DiagnosticCode.cancelled
            case .responseTooLarge:
                throw DiagnosticCode.polishInvalidResponse
            case .redirectRejected, .network, .invalidHTTPResponse:
                throw DiagnosticCode.polishTransport
            }
        } catch is CancellationError {
            throw DiagnosticCode.cancelled
        } catch {
            throw DiagnosticCode.polishInvalidResponse
        }
    }

    public func validate(
        profile: ProviderProfile,
        credential: SessionSecret
    ) async -> ProviderValidationResult {
        do {
            try Task.checkCancellation()
            let endpoint = try validatedEndpoint(
                profile.baseURL,
                requiring: profile.policy
            )
            guard !profile.modelID.isEmpty else {
                return .failed(.polishInvalidResponse)
            }
            let credential = credentialValue(credential)
            if endpoint.policy == .remoteHTTPS, credential.isEmpty {
                return .failed(.credentialMissing)
            }
            let url = try apiURL(endpoint.requestBaseURL, suffix: "models")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            if !credential.isEmpty {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
            let response = try await transport(request)
            guard (200...299).contains(response.statusCode) else {
                return .failed(statusCode(response.statusCode))
            }
            let models = try JSONDecoder().decode(ModelsResponse.self, from: response.body)
            guard models.data.contains(where: { $0.id == profile.modelID }) else {
                return .failed(.polishInvalidResponse)
            }
            return .ready(
                normalizedHost: endpoint.displayAuthority,
                modelID: profile.modelID
            )
        } catch let failure as TransportFailure {
            switch failure {
            case .cancelled: return .failed(.cancelled)
            case .responseTooLarge: return .failed(.polishInvalidResponse)
            case .redirectRejected, .network, .invalidHTTPResponse:
                return .failed(.polishTransport)
            }
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch let code as DiagnosticCode {
            return .failed(code)
        } catch {
            return .failed(.polishInvalidResponse)
        }
    }

    private func validatedEndpoint(
        _ url: URL,
        requiring policy: EndpointPolicy
    ) throws -> ValidatedEndpoint {
        let endpoint: ValidatedEndpoint
        do {
            endpoint = try EndpointValidator.validate(
                url.absoluteString,
                requiring: policy,
                resolver: resolver
            )
            try EndpointValidator.revalidate(endpoint, resolver: resolver)
        } catch {
            throw DiagnosticCode.polishTransport
        }
        return endpoint
    }

    private func credentialValue(_ credential: SessionSecret?) -> String {
        guard let credential else { return "" }
        return (try? credential.withUTF8 { $0 }) ?? ""
    }

    private func apiURL(_ baseURL: URL, suffix: String) throws -> URL {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw DiagnosticCode.polishTransport
        }
        let basePath = components.percentEncodedPath == "/"
            ? ""
            : components.percentEncodedPath
        components.percentEncodedPath = "\(basePath)/\(suffix)"
        guard let url = components.url else {
            throw DiagnosticCode.polishTransport
        }
        return url
    }

    private func transport(_ request: URLRequest) async throws -> TransportResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldUsePipelining = false
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses
        }
        configurationObserver(configuration)
        let delegate = BoundedSessionDelegate(
            byteLimit: Self.byteLimit,
            initialRequest: request
        )
        return try await delegate.execute(
            request: request,
            configuration: configuration,
            factory: sessionFactory
        )
    }

    private func statusCode(_ status: Int) -> DiagnosticCode {
        status == 401 || status == 403
            ? .polishAuthentication
            : .polishTransport
    }

    private func cleanedContent(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        var value = response.choiceZero.message.content.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = stripOuterFence(value)
        value = try stripReasoningBlocks(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = stripOuterFence(value)
        guard !value.isEmpty, !isStructuredJSON(value) else {
            throw DiagnosticCode.polishInvalidResponse
        }
        return value
    }

    private func stripOuterFence(_ value: String) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return value }
        let opening = String(lines[0]).trimmingCharacters(in: .whitespaces)
        guard let markerCharacter = opening.first,
              markerCharacter == "`" || markerCharacter == "~" else {
            return value
        }
        let markerLength = opening.prefix { $0 == markerCharacter }.count
        guard markerLength >= 3 else { return value }
        let marker = String(repeating: String(markerCharacter), count: markerLength)
        guard !opening.dropFirst(markerLength).contains(markerCharacter),
              String(lines[lines.count - 1]).trimmingCharacters(in: .whitespaces) == marker else {
            return value
        }
        return lines[1..<(lines.count - 1)]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripReasoningBlocks(_ value: String) throws -> String {
        let complete = try NSRegularExpression(
            pattern: #"(?is)<(think|analysis|reasoning)\b[^>]*>.*?</\1\s*>"#
        )
        var result = value
        while true {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let matches = complete.matches(in: result, range: range)
            guard !matches.isEmpty else { break }
            result = complete.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: ""
            )
        }
        let residual = try NSRegularExpression(
            pattern: #"(?i)</?(think|analysis|reasoning)\b"#
        )
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        guard residual.firstMatch(in: result, range: range) == nil else {
            throw DiagnosticCode.polishInvalidResponse
        }
        return result
    }

    private func isStructuredJSON(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              json is [Any] || json is [String: Any] else {
            return false
        }
        return true
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
}

private struct Message: Codable {
    let role: String
    let content: String
}

private struct ChatResponse: Decodable {
    let choiceZero: Choice

    private enum CodingKeys: String, CodingKey {
        case choices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var choices = try container.nestedUnkeyedContainer(forKey: .choices)
        choiceZero = try choices.decode(Choice.self)
    }

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let content: ResponseContent
    }
}

private enum ResponseContent: Decodable {
    case string(String)
    case textParts([TextPart])

    var value: String {
        switch self {
        case let .string(value): value
        case let .textParts(parts): parts.map(\.text).joined()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        let parts = try container.decode([TextPart].self)
        guard parts.allSatisfy({ $0.type == "text" }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported content"
            )
        }
        self = .textParts(parts)
    }
}

private struct TextPart: Decodable {
    let type: String
    let text: String
}

private struct ModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}
