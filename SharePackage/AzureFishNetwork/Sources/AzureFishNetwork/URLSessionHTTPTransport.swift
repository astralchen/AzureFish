import Foundation

/// 使用独立临时 URLSession 执行前台请求的传输实现。
///
/// 关闭 URLCache、Cookie 存储及凭据存储，保持系统 TLS 校验并拒绝所有重定向。
/// 实例持有 session，释放时使其失效并请求取消所属任务；不提供后台续传或自动重试。
public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let security: TransportSecurityPolicy
    private let redirectDelegate = RedirectDelegate()

    /// 创建采用指定地址策略的临时 session，尚不发起请求。
    ///
    /// 资源超时设为 60 秒，单次请求间隔由 HTTPRequest 的 timeout 指定；不等待网络恢复。
    ///
    /// - Parameter security: 请求地址的校验策略，默认 `.httpsOnly`。
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

    /// 发送一次请求，逐字节接收响应，并在完成后返回内存中的正文。
    ///
    /// 若已知响应长度或实际收到的数据超过上限，则终止任务并抛错。拒绝重定向时保留原始
    /// 3xx 响应，是否接受该状态由上层判断。取消会请求取消底层任务；接收流程结束时同样清理任务。
    ///
    /// - Parameter request: 本次请求，包含原始正文、单次超时和接收字节上限。
    /// - Returns: 完整 HTTP 响应；不解析 Protobuf，也不把 HTTP 错误状态转换为业务错误。
    /// - Throws: `CancellationError`，或地址、参数、响应类型、大小及系统网络失败对应的 `NetworkError`。
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
