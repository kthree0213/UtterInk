import Darwin
import Foundation
import UtterInkCore

package protocol HostResolver: Sendable {
    func resolve(_ host: String) throws -> [String]
}

package struct SystemHostResolver: HostResolver {
    package init() {}

    package func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw EndpointValidationError.resolutionFailed
        }
        defer { freeaddrinfo(first) }

        var answers: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            guard let address = current.pointee.ai_addr else {
                cursor = current.pointee.ai_next
                continue
            }
            switch Int32(current.pointee.ai_family) {
            case AF_INET:
                var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &value, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    answers.append(String(cString: buffer))
                }
            case AF_INET6:
                var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &value, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    answers.append(String(cString: buffer))
                }
            default:
                break
            }
            cursor = current.pointee.ai_next
        }
        guard !answers.isEmpty else {
            throw EndpointValidationError.resolutionFailed
        }
        return answers
    }
}

package enum EndpointValidationError: String, Error, Equatable, Sendable,
    CustomStringConvertible, LocalizedError {
    case malformed
    case unsupportedScheme
    case forbiddenComponent
    case invalidHost
    case invalidPort
    case policyMismatch
    case resolutionFailed
    case resolutionChanged

    package var description: String { "endpoint.\(rawValue)" }
    package var errorDescription: String? { description }
}

package struct EndpointOrigin: Equatable, Sendable {
    package let scheme: String
    package let host: String
    package let effectivePort: Int
}

package struct LocalhostResolution: Equatable, Sendable {
    package let selectedLiteral: String
    package let answers: Set<String>
}

public struct ValidatedEndpoint: Equatable, Sendable {
    public let requestBaseURL: URL
    public let displayAuthority: String
    public let policy: EndpointPolicy

    package let origin: EndpointOrigin
    package let localhostResolution: LocalhostResolution?

    package init(
        requestBaseURL: URL,
        displayAuthority: String,
        policy: EndpointPolicy,
        origin: EndpointOrigin,
        localhostResolution: LocalhostResolution?
    ) {
        self.requestBaseURL = requestBaseURL
        self.displayAuthority = displayAuthority
        self.policy = policy
        self.origin = origin
        self.localhostResolution = localhostResolution
    }
}

public enum EndpointValidator {
    public static func validate(_ value: String) throws -> ValidatedEndpoint {
        try validate(value, requiring: nil, resolver: SystemHostResolver())
    }

    package static func validate(
        _ value: String,
        requiring requiredPolicy: EndpointPolicy? = nil,
        resolver: any HostResolver
    ) throws -> ValidatedEndpoint {
        guard !value.isEmpty, !containsControl(value), !containsEncodedControl(value) else {
            throw EndpointValidationError.malformed
        }
        guard let components = URLComponents(string: value),
              let rawScheme = components.scheme,
              value.range(
                of: "\(rawScheme)://",
                options: [.anchored, .caseInsensitive]
              ) != nil else {
            throw EndpointValidationError.malformed
        }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw EndpointValidationError.unsupportedScheme
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw EndpointValidationError.forbiddenComponent
        }
        guard !containsControl(components.path) else {
            throw EndpointValidationError.forbiddenComponent
        }

        let authority = try parseAuthority(value, scheme: rawScheme)
        guard !authority.host.isEmpty else {
            throw EndpointValidationError.invalidHost
        }
        if authority.host.contains("%") || authority.host.contains("\\") {
            throw EndpointValidationError.invalidHost
        }

        let policy: EndpointPolicy
        let requestHost: String
        let displayHost: String
        let localhostResolution: LocalhostResolution?

        if scheme == "https" {
            policy = .remoteHTTPS
            requestHost = authority.host
            displayHost = authority.host.lowercased()
            localhostResolution = nil
        } else {
            policy = .loopbackHTTP
            displayHost = authority.host
            if authority.host == "localhost" {
                let answers = try sanitizedResolution(of: "localhost", using: resolver)
                let selected = selectLoopback(from: answers)
                requestHost = bracketIfIPv6(selected)
                localhostResolution = LocalhostResolution(
                    selectedLiteral: selected,
                    answers: answers
                )
            } else if isCanonical127(authority.host) {
                requestHost = authority.host
                localhostResolution = nil
            } else if authority.host == "[::1]" {
                requestHost = authority.host
                localhostResolution = nil
            } else {
                throw EndpointValidationError.invalidHost
            }
        }

        if let requiredPolicy, requiredPolicy != policy {
            throw EndpointValidationError.policyMismatch
        }

        var requestComponents = components
        requestComponents.scheme = scheme
        requestComponents.host = requestHost
        requestComponents.port = authority.port
        requestComponents.user = nil
        requestComponents.password = nil
        requestComponents.query = nil
        requestComponents.fragment = nil
        requestComponents.percentEncodedPath = normalizedPath(components.percentEncodedPath)
        guard let requestBaseURL = requestComponents.url else {
            throw EndpointValidationError.malformed
        }

        let effectivePort = authority.port ?? (scheme == "https" ? 443 : 80)
        let originHost = unbracket(requestHost).lowercased()
        let displayAuthority = authority.explicitPort
            ? "\(displayHost):\(authority.port!)"
            : displayHost
        return ValidatedEndpoint(
            requestBaseURL: requestBaseURL,
            displayAuthority: displayAuthority,
            policy: policy,
            origin: EndpointOrigin(
                scheme: scheme,
                host: originHost,
                effectivePort: effectivePort
            ),
            localhostResolution: localhostResolution
        )
    }

    package static func revalidate(
        _ endpoint: ValidatedEndpoint,
        resolver: any HostResolver
    ) throws {
        guard let initial = endpoint.localhostResolution else { return }
        let current = try sanitizedResolution(of: "localhost", using: resolver)
        guard current == initial.answers,
              current.contains(initial.selectedLiteral) else {
            throw EndpointValidationError.resolutionChanged
        }
    }

    private struct ParsedAuthority {
        let host: String
        let port: Int?
        let explicitPort: Bool
    }

    private static func parseAuthority(
        _ value: String,
        scheme: String
    ) throws -> ParsedAuthority {
        guard let delimiter = value.range(of: "://", options: [.caseInsensitive]),
              delimiter.lowerBound == value.index(value.startIndex, offsetBy: scheme.count) else {
            throw EndpointValidationError.malformed
        }
        let tail = value[delimiter.upperBound...]
        let end = tail.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? tail.endIndex
        let authority = String(tail[..<end])
        guard !authority.isEmpty, !authority.contains("@") else {
            throw EndpointValidationError.invalidHost
        }

        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else {
                throw EndpointValidationError.invalidHost
            }
            let host = String(authority[...close])
            let remainder = authority[authority.index(after: close)...]
            if remainder.isEmpty {
                return ParsedAuthority(host: host, port: nil, explicitPort: false)
            }
            guard remainder.first == ":" else {
                throw EndpointValidationError.invalidHost
            }
            let port = try parsePort(String(remainder.dropFirst()))
            return ParsedAuthority(host: host, port: port, explicitPort: true)
        }

        let colonCount = authority.reduce(into: 0) { count, character in
            if character == ":" { count += 1 }
        }
        guard colonCount <= 1 else {
            throw EndpointValidationError.invalidHost
        }
        if let colon = authority.lastIndex(of: ":") {
            let host = String(authority[..<colon])
            let port = try parsePort(String(authority[authority.index(after: colon)...]))
            return ParsedAuthority(host: host, port: port, explicitPort: true)
        }
        return ParsedAuthority(host: authority, port: nil, explicitPort: false)
    }

    private static func parsePort(_ value: String) throws -> Int {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(value),
              (1...65_535).contains(port) else {
            throw EndpointValidationError.invalidPort
        }
        return port
    }

    private static func sanitizedResolution(
        of host: String,
        using resolver: any HostResolver
    ) throws -> Set<String> {
        let values: [String]
        do {
            values = try resolver.resolve(host)
        } catch {
            throw EndpointValidationError.resolutionFailed
        }
        let answers = Set(values)
        guard !answers.isEmpty,
              answers.allSatisfy({ $0 == "::1" || isCanonical127($0) }) else {
            throw EndpointValidationError.resolutionFailed
        }
        return answers
    }

    private static func selectLoopback(from answers: Set<String>) -> String {
        if answers.contains("127.0.0.1") { return "127.0.0.1" }
        if let firstIPv4 = answers.filter(isCanonical127).sorted().first {
            return firstIPv4
        }
        return "::1"
    }

    private static func isCanonical127(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return false }
        var octets: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty,
                  piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  (piece.count == 1 || piece.first != "0"),
                  let number = Int(piece),
                  (0...255).contains(number) else {
                return false
            }
            octets.append(number)
        }
        return octets.first == 127
    }

    private static func normalizedPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result.isEmpty ? "/" : result
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func containsEncodedControl(_ value: String) -> Bool {
        let scalars = Array(value.utf8)
        guard scalars.count >= 3 else { return false }
        for index in 0..<(scalars.count - 2) where scalars[index] == 0x25 {
            guard let high = hexValue(scalars[index + 1]),
                  let low = hexValue(scalars[index + 2]) else { continue }
            let byte = high * 16 + low
            if byte < 0x20 || byte == 0x7F { return true }
        }
        return false
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 65 + 10
        case 97...102: return byte - 97 + 10
        default: return nil
        }
    }

    private static func bracketIfIPv6(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }

    private static func unbracket(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }
}
