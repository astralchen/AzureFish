import Foundation

/// 无缓存、无 cookie 持久化的前台传输，使用系统 TLS 校验并拒绝全部重定向。
public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let security: TransportSecurityPolicy
    private let redirectDelegate = RedirectDelegate()

    public init(security: TransportSecurityPolicy = .httpsOnly) {
        self.security = security
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    /// 按需消费字节；已知 Content-Length 或实际解压后数据超限时取消底层任务。
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        try security.validate(request.url)
        do {
            let (bytes, response) = try await session.bytes(for: request.urlRequest(), delegate: redirectDelegate)
            defer { bytes.task.cancel() }
            return try await withTaskCancellationHandler {
                guard let response = response as? HTTPURLResponse else { throw NetworkError.nonHTTPResponse }
                guard response.expectedContentLength <= request.maximumResponseBytes else {
                    throw NetworkError.responseTooLarge(limit: request.maximumResponseBytes)
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < request.maximumResponseBytes else {
                        throw NetworkError.responseTooLarge(limit: request.maximumResponseBytes)
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
                return HTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
            } onCancel: { bytes.task.cancel() }
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? NetworkError { throw error }
            if let error = error as? URLError { throw NetworkError.transport(code: error.code) }
            throw NetworkError.transportFailed
        }
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // 不把 Authorization 或含密码的正文转发给重定向地址，包括同域的 307／308。
        completionHandler(nil)
    }
}
