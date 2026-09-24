import Foundation

/// 执行不可变请求，在明确允许的传输故障后最多重试一次，不解释业务状态码。
public struct HTTPClient: Sendable {
    private let transport: any HTTPTransport
    private let security: TransportSecurityPolicy
    private let waitBeforeRetry: @Sendable () async throws -> Void

    public init(transport: (any HTTPTransport)? = nil, security: TransportSecurityPolicy = .httpsOnly,
                waitBeforeRetry: @escaping @Sendable () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) }) {
        self.transport = transport ?? URLSessionHTTPTransport(security: security)
        self.security = security; self.waitBeforeRetry = waitBeforeRetry
    }

    /// 每次发送产生不同的 X-Request-ID；重试保持 method、URL、其他头与 body 的原始字节。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try security.validate(request.url)
        _ = try request.urlRequest()
        for attempt in 0...1 {
            try Task.checkCancellation()
            var headers = request.headers.filter { $0.key.caseInsensitiveCompare("X-Request-ID") != .orderedSame }
            headers["X-Request-ID"] = UUID().uuidString.lowercased()
            let outgoing = HTTPRequest(url: request.url, method: request.method, headers: headers, body: request.body,
                                       timeout: request.timeout, maximumResponseBytes: request.maximumResponseBytes, replayPolicy: request.replayPolicy)
            do {
                let response = try await transport.send(outgoing)
                try Task.checkCancellation()
                guard response.body.count <= request.maximumResponseBytes else { throw NetworkError.responseTooLarge(limit: request.maximumResponseBytes) }
                return response
            } catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                let mapped = (error as? NetworkError) ?? (error as? URLError).map { .transport(code: $0.code) } ?? .transportFailed
                guard attempt == 0, retryAllowed(request, error: mapped) else { throw mapped }
                try await waitBeforeRetry()
            }
        }
        throw NetworkError.transportFailed
    }

    private func retryAllowed(_ request: HTTPRequest, error: NetworkError) -> Bool {
        guard case .transport(let code) = error else { return false }
        switch request.replayPolicy {
        case .never: return false
        case .readOnce:
            return request.method == .get && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code)
        case .idempotentWriteOnce:
            return request.method != .get && request.body != nil && [.timedOut, .networkConnectionLost].contains(code)
        }
    }
}
