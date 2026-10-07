import Foundation

/// 使用独立临时 URLSession 执行前台请求的传输实现。
///
/// 关闭 URLCache、Cookie 存储及凭据存储，保持系统 TLS 校验并拒绝所有重定向。
/// 实例持有 session，释放时使其失效并请求取消所属任务；不提供后台续传或自动重试。
public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    /// 此传输持有的临时 URLSession；释放传输时取消所属任务。
    private let session: URLSession
    /// 发送前检查请求地址的安全策略。
    private let security: TransportSecurityPolicy

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

    /// 使所属 session 失效并请求取消尚未结束的任务。
    deinit { session.invalidateAndCancel() }

    /// 发送一次请求，按系统提供的数据块接收响应，并在完成后返回内存中的正文。
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
            let delegate = ResponseReceiver(limit: request.maximumResponseBytes)
            let task = session.dataTask(with: try request.urlRequest())
            task.delegate = delegate
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.begin(task, continuation: continuation)
                }
            } onCancel: { delegate.cancel() }
            try Task.checkCancellation()
            return response
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let error = error as? NetworkError { throw error }
            if let error = error as? URLError { throw NetworkError.transport(code: error.code) }
            throw NetworkError.transportFailed
        }
    }
}

/// 回调及取消共同访问的接收状态由 lock 保护；每个请求持有独立实例。
private final class ResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var finished = false
    private var cancelled = false
    init(limit: Int) { self.limit = limit }

    func begin(_ task: URLSessionDataTask, continuation: CheckedContinuation<HTTPResponse, Error>) {
        lock.lock()
        if cancelled {
            finished = true
            lock.unlock()
            task.cancel()
            continuation.resume(throwing: CancellationError())
        } else {
            self.task = task; self.continuation = continuation
            task.resume()
            lock.unlock()
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()), cancelling: true)
    }
    private func finish(_ result: Result<HTTPResponse, Error>, cancelling: Bool = false) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        let task = task
        self.task = nil; self.continuation = nil
        data = Data(); response = nil
        lock.unlock()
        if cancelling { task?.cancel() }
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(NetworkError.nonHTTPResponse)); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(NetworkError.responseTooLarge(limit: limit))); return
        }
        lock.lock()
        self.response = finished ? nil : response
        let allow = !finished
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard bytes.count <= limit - data.count else {
            lock.unlock()
            finish(.failure(NetworkError.responseTooLarge(limit: limit)), cancelling: true)
            return
        }
        data.append(bytes)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let response = response, body = data
        lock.unlock()
        if let error { finish(.failure(error)) }
        else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
            finish(.success(HTTPResponse(statusCode: response.statusCode, headers: headers, body: body)))
        } else { finish(.failure(NetworkError.nonHTTPResponse)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
