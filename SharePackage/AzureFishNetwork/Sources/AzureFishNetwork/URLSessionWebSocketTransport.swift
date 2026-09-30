import Foundation

/// 使用系统 TLS 验证的单次原生连接；实例不能用于第二次握手。
public actor URLSessionWebSocketTransport: WebSocketTransport {
    /// 握手前校验 WS／WSS 地址的安全策略。
    private let security: TransportSecurityPolicy
    /// 接收握手及关闭回调并将系统错误映射为脱敏错误的代理。
    private let delegate = SocketDelegate()
    /// 握手时创建的临时 URLSession；close 后清空。
    private var session: URLSession?
    /// 此实例唯一的 WebSocket 任务；关闭后不允许再次握手。
    private var task: URLSessionWebSocketTask?
    /// 实例是否已永久关闭，初始为 false。
    private var closed = false
    /// 当前连接的应用消息字节上限，握手时设置并用于发送校验。
    private var maximumMessageBytes = 1_048_576

    /// 保存握手安全策略；URLSession 和 WebSocket 任务在 connect 时创建。
    public init(security: TransportSecurityPolicy = .httpsOnly) { self.security = security }

    /// 校验地址、请求头和消息上限，然后等待系统握手回调。
    ///
    /// 实例仅允许一次握手；等待失败会关闭传输。接收使用临时会话，拒绝重定向。
    public func connect(_ handshake: WebSocketHandshake, maximumMessageBytes: Int) async throws {
        guard !closed, task == nil else { throw WebSocketError.shutdown }
        try security.validateWebSocket(handshake.url)
        guard maximumMessageBytes > 0 else { throw WebSocketError.invalidConfiguration }
        self.maximumMessageBytes = maximumMessageBytes
        // 复用 HTTP 请求头校验，避免换行注入；URL 校验采用上面的 WS 策略。
        let validated = HTTPRequest(url: handshake.url, method: .get, headers: handshake.headers)
        var request: URLRequest
        do { request = try validated.urlRequest() } catch { throw WebSocketError.invalidHandshake }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 365 * 24 * 60 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageBytes
        self.task = task
        task.resume()
        do { try await delegate.opened.value() }
        catch { await close(); throw error }
        guard !closed else { throw CancellationError() }
    }

    /// 校验连接和正文上限后提交消息；返回只表示系统发送完成，错误经脱敏映射。
    public func send(_ message: WebSocketMessage) async throws {
        guard !closed, let task else { throw WebSocketError.notConnected }
        guard message.byteCount <= maximumMessageBytes else { throw WebSocketError.messageTooLarge }
        do {
            switch message {
            case .text(let text): try await task.send(.string(text))
            case .binary(let data): try await task.send(.data(data))
            }
        } catch { throw delegate.failure(task: task, error: error) }
    }

    /// 等待下一条文本或二进制消息；底层错误转换为脱敏 WebSocketError。
    public func receive() async throws -> WebSocketMessage {
        guard !closed, let task else { throw WebSocketError.notConnected }
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .binary(data)
            @unknown default: throw WebSocketError.transportFailed
            }
        } catch { throw delegate.failure(task: task, error: error) }
    }

    /// 提交一次系统 ping 并等待 pong 回调；调用任务取消只取消本次结果等待。
    public func ping() async throws {
        guard !closed, let task else { throw WebSocketError.notConnected }
        let promise = NetworkPromise<Void>()
        task.sendPing { [delegate] error in
            if let error { promise.resolve(.failure(delegate.failure(task: task, error: error))) }
            else { promise.resolve(.success(())) }
        }
        try await promise.value()
    }

    /// 永久标记关闭，取消握手等待及系统任务并释放会话；可重复调用。
    public func close() async {
        closed = true
        delegate.opened.resolve(.failure(CancellationError()))
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil; session = nil
    }

    /// 使持有的 URLSession 失效并请求取消其任务。
    deinit { session?.invalidateAndCancel() }
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// 握手打开、关闭或失败共同竞争的单次完成结果。
    let opened = NetworkPromise<Void>()
    /// 保护来自系统回调的关闭代码的互斥锁。
    private let lock = NSLock()
    /// 已接收到的 WebSocket 关闭代码；nil 表示尚未收到关闭回调。
    private var closeCode: Int?

    /// 由 URLSession 在握手成功时调用，以成功结果恢复握手等待者。
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened.resolve(.success(()))
    }
    /// 由 URLSession 在收到关闭帧时调用，保存脱敏关闭代码并尝试结束握手等待。
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock(); self.closeCode = closeCode.rawValue; lock.unlock()
        opened.resolve(.failure(WebSocketError.closed(code: closeCode.rawValue)))
    }
    /// 由 URLSession 在任务结束时调用，将脱敏失败结果交给尚未完成的握手等待者。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        opened.resolve(.failure(failure(task: task, error: error)))
    }
    /// 由 URLSession 在握手重定向时调用，报告握手拒绝并以 nil 拒绝重定向。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        opened.resolve(.failure(WebSocketError.handshakeRejected(status: response.statusCode)))
        completionHandler(nil)
    }
    /// 优先识别超限、关闭代码和握手拒绝，其余错误只保留脱敏传输分类。
    func failure(task: URLSessionTask, error: (any Error)?) -> WebSocketError {
        if (error as? URLError)?.code == .dataLengthExceedsMaximum { return .messageTooLarge }
        lock.lock(); let code = closeCode; lock.unlock()
        if let code { return .closed(code: code) }
        if let socket = task as? URLSessionWebSocketTask, socket.closeCode != .invalid {
            return .closed(code: socket.closeCode.rawValue)
        }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            return .handshakeRejected(status: response.statusCode)
        }
        return error.map(WebSocketError.sanitize) ?? .transportFailed
    }
}
