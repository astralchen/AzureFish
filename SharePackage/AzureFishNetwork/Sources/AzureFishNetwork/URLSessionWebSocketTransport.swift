import Foundation

/// 使用系统 TLS 验证的单次原生连接；实例不能用于第二次握手。
public actor URLSessionWebSocketTransport: WebSocketTransport {
    private let security: TransportSecurityPolicy
    private let delegate = SocketDelegate()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var maximumMessageBytes = 1_048_576

    public init(security: TransportSecurityPolicy = .httpsOnly) { self.security = security }

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

    public func ping() async throws {
        guard !closed, let task else { throw WebSocketError.notConnected }
        let promise = NetworkPromise<Void>()
        task.sendPing { [delegate] error in
            if let error { promise.resolve(.failure(delegate.failure(task: task, error: error))) }
            else { promise.resolve(.success(())) }
        }
        try await promise.value()
    }

    public func close() async {
        closed = true
        delegate.opened.resolve(.failure(CancellationError()))
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil; session = nil
    }

    deinit { session?.invalidateAndCancel() }
}

private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened = NetworkPromise<Void>()
    private let lock = NSLock()
    private var closeCode: Int?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        opened.resolve(.success(()))
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock(); self.closeCode = closeCode.rawValue; lock.unlock()
        opened.resolve(.failure(WebSocketError.closed(code: closeCode.rawValue)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        opened.resolve(.failure(failure(task: task, error: error)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        opened.resolve(.failure(WebSocketError.handshakeRejected(status: response.statusCode)))
        completionHandler(nil)
    }
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
