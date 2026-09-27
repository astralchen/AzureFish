import Foundation

/// 请求配对凭据；业务适配层须将 identity 和 nonce 与其帧格式关联。
public struct WebSocketRequestToken<Identity: Hashable & Sendable>: Sendable, Hashable {
    public let identity: Identity
    public let nonce: UUID
    public let generation: UUID
}

/// 与业务帧格式无关的请求配对器。断线时调用 invalidate，旧 token 永远无法完成新请求。
public actor WebSocketRequestBroker<Identity: Hashable & Sendable, Response: Sendable> {
    private struct Pending {
        let token: WebSocketRequestToken<Identity>
        let promise: NetworkPromise<Response>
        let timeout: Task<Void, Never>
        let send: Task<Void, Never>
    }
    private var generation = UUID()
    private var pending: [Identity: Pending] = [:]
    private let clock: any NetworkClock
    public init(clock: any NetworkClock = SystemNetworkClock()) { self.clock = clock }

    /// 先注册响应等待，再调用 send，因此同步到达的快速响应也能正确配对。
    public func request(identity: Identity, timeout: TimeInterval = 15,
                        send: @escaping @Sendable (WebSocketRequestToken<Identity>) async throws -> Void) async throws -> Response {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw WebSocketError.invalidConfiguration }
        guard pending[identity] == nil else { throw WebSocketError.duplicateRequest }
        let token = WebSocketRequestToken(identity: identity, nonce: UUID(), generation: generation)
        let promise = NetworkPromise<Response>(), clock = clock
        let timer = Task { [weak self] in
            do { try await clock.sleep(seconds: timeout); try Task.checkCancellation(); await self?.fail(token, error: WebSocketError.requestTimeout) } catch {}
        }
        let work = Task { [weak self] in
            do { try await send(token) } catch { await self?.fail(token, error: error) }
        }
        pending[identity] = Pending(token: token, promise: promise, timeout: timer, send: work)
        defer { remove(token) }
        return try await promise.value()
    }

    @discardableResult
    public func resolve(_ response: Response, for token: WebSocketRequestToken<Identity>) -> Bool {
        guard token.generation == generation, let item = pending[token.identity], item.token == token else { return false }
        item.promise.resolve(.success(response)); remove(token)
        return true
    }

    /// 终止全部请求并更新代次。不会关闭底层连接。
    public func invalidate() {
        generation = UUID()
        for item in pending.values {
            item.promise.resolve(.failure(WebSocketError.staleGeneration)); item.timeout.cancel(); item.send.cancel()
        }
        pending.removeAll()
    }
    private func fail(_ token: WebSocketRequestToken<Identity>, error: any Error) {
        guard let item = pending[token.identity], item.token == token else { return }
        item.promise.resolve(.failure(error)); remove(token)
    }
    private func remove(_ token: WebSocketRequestToken<Identity>) {
        guard let item = pending[token.identity], item.token == token else { return }
        pending.removeValue(forKey: token.identity); item.timeout.cancel(); item.send.cancel()
    }
    deinit {
        for item in pending.values {
            item.promise.resolve(.failure(WebSocketError.shutdown)); item.timeout.cancel(); item.send.cancel()
        }
    }
}

/// 基于注册 token 的路由器；单次投递使用处理器快照，并发执行且不保证回调顺序。
public actor MessageRouter<Route: Hashable & Sendable, Message: Sendable> {
    public struct Token: Hashable, Sendable { fileprivate let id: UUID }
    private struct Registration: Sendable {
        let routes: Set<Route>
        let handler: @Sendable (Message) async -> Void
    }
    private var handlers: [Token: Registration] = [:]
    public init() {}
    public func register(routes: Set<Route>, handler: @escaping @Sendable (Message) async -> Void) -> Token {
        let token = Token(id: UUID())
        handlers[token] = Registration(routes: routes, handler: handler)
        return token
    }
    /// 阻止后续投递；已取得快照的回调仍会完成，不被取消。
    public func unregister(_ token: Token) { handlers.removeValue(forKey: token) }
    public func route(_ message: Message, to route: Route) async {
        let selected = handlers.values.filter { $0.routes.contains(route) }
        await withTaskGroup(of: Void.self) { group in
            for item in selected { group.addTask { await item.handler(message) } }
        }
    }
}
