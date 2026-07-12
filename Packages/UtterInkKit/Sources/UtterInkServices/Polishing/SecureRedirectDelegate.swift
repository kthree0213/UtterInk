import Foundation

package enum TransportFailure: Error, Equatable, Sendable,
    CustomStringConvertible, LocalizedError {
    case cancelled
    case redirectRejected
    case responseTooLarge
    case network
    case invalidHTTPResponse

    package var description: String {
        switch self {
        case .cancelled: "transport.cancelled"
        case .redirectRejected: "transport.redirect_rejected"
        case .responseTooLarge: "transport.response_too_large"
        case .network: "transport.network"
        case .invalidHTTPResponse: "transport.invalid_response"
        }
    }

    package var errorDescription: String? { description }
}

package struct TransportResult: Sendable {
    package let statusCode: Int
    package let body: Data
}

package protocol URLSessionCreating: Sendable {
    func makeSession(
        configuration: URLSessionConfiguration,
        delegate: BoundedSessionDelegate
    ) -> URLSession
}

package struct SystemURLSessionFactory: URLSessionCreating {
    package init() {}

    package func makeSession(
        configuration: URLSessionConfiguration,
        delegate: BoundedSessionDelegate
    ) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

package final class SecureRedirectDelegate: NSObject {
    package static func redirectedRequest(
        from original: URLRequest,
        to proposed: URLRequest
    ) -> URLRequest? {
        guard let originalURL = original.url,
              let proposedURL = proposed.url,
              let originalComponents = URLComponents(
                url: originalURL,
                resolvingAgainstBaseURL: false
              ),
              let proposedComponents = URLComponents(
                url: proposedURL,
                resolvingAgainstBaseURL: false
              ),
              originalComponents.scheme?.lowercased() == "https",
              proposedComponents.scheme?.lowercased() == "https",
              proposedComponents.user == nil,
              proposedComponents.password == nil,
              proposedComponents.query == nil,
              proposedComponents.fragment == nil,
              sameOrigin(originalComponents, proposedComponents) else {
            return nil
        }

        var sanitized = proposed
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        if let authorization = original.value(forHTTPHeaderField: "Authorization") {
            sanitized.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return sanitized
    }

    private static func sameOrigin(
        _ lhs: URLComponents,
        _ rhs: URLComponents
    ) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = normalizedHost(lhs.host),
              let rhsHost = normalizedHost(rhs.host) else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ components: URLComponents) -> Int {
        if let port = components.port { return port }
        return components.scheme?.lowercased() == "https" ? 443 : 80
    }

    private static func normalizedHost(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value.lowercased()
    }
}

package final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable {
    private let byteLimit: Int
    private let initialRequest: URLRequest
    private let lock = NSLock()

    private var continuation: CheckedContinuation<TransportResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var explicitFailure: TransportFailure?
    private var cancellationRequested = false
    private var completed = false

    package init(byteLimit: Int, initialRequest: URLRequest) {
        self.byteLimit = byteLimit
        self.initialRequest = initialRequest
    }

    package func execute(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        factory: any URLSessionCreating
    ) async throws -> TransportResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = factory.makeSession(
                    configuration: configuration,
                    delegate: self
                )
                let task = session.dataTask(with: request)
                let wasCancelled = lock.withLock { () -> Bool in
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    return cancellationRequested
                }
                task.resume()
                if wasCancelled {
                    task.cancel()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    package func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !completed else { return nil }
            cancellationRequested = true
            if explicitFailure == nil {
                explicitFailure = .cancelled
            }
            return self.task
        }
        task?.cancel()
    }

    package func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            setFailure(.invalidHTTPResponse)
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        let isOversized = response.expectedContentLength > Int64(byteLimit)
        lock.withLock {
            self.response = http
            if isOversized, explicitFailure == nil {
                explicitFailure = .responseTooLarge
            }
        }
        completionHandler(isOversized ? .cancel : .allow)
        if isOversized { dataTask.cancel() }
    }

    package func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard explicitFailure == nil else { return false }
            guard data.count <= byteLimit - body.count else {
                explicitFailure = .responseTooLarge
                return true
            }
            body.append(data)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let allowed = SecureRedirectDelegate.redirectedRequest(
                from: initialRequest,
                to: request
              ) else {
            setFailure(.redirectRejected)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(allowed)
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let result: Result<TransportResult, Error> = lock.withLock {
            if let explicitFailure {
                return .failure(explicitFailure)
            }
            if error != nil {
                return .failure(
                    cancellationRequested ? TransportFailure.cancelled : .network
                )
            }
            guard let response else {
                return .failure(TransportFailure.invalidHTTPResponse)
            }
            return .success(
                TransportResult(statusCode: response.statusCode, body: body)
            )
        }
        finish(result)
    }

    private func setFailure(_ failure: TransportFailure) {
        lock.withLock {
            if explicitFailure == nil {
                explicitFailure = failure
            }
        }
    }

    private func finish(_ result: Result<TransportResult, Error>) {
        let values = lock.withLock {
            () -> (CheckedContinuation<TransportResult, Error>?, URLSession?) in
            guard !completed else { return (nil, nil) }
            completed = true
            let continuation = self.continuation
            let session = self.session
            self.continuation = nil
            self.session = nil
            self.task = nil
            return (continuation, session)
        }
        guard let continuation = values.0 else { return }
        continuation.resume(with: result)
        values.1?.finishTasksAndInvalidate()
    }
}
