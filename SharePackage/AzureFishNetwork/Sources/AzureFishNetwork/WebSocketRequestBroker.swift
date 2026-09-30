import Foundation

/// 请求配对凭据；业务适配层须将 identity 和 nonce 与其帧格式关联。
public struct WebSocketRequestToken<Identity: Hashable & Sendable>: Sendable, Hashable {
    /// 业务请求的配对身份；同一代次中不能同时存在两个相同身份的待处理请求。
    public let identity: Identity
    /// 每次登记生成的随机标识，防止同身份的迟到响应完成后续请求。
    public let nonce: UUID
    /// 请求登记时的配对器代次；invalidate 后不再有效。
    public let generation: UUID
}

/// 与业务帧格式无关的请求配对器。断线时调用 invalidate，旧 token 永远无法完成新请求。
public actor WebSocketRequestBroker<Identity: Hashable & Sendable, Response: Sendable> {
    private struct Pending {
        /// 本次登记的完整配对凭据。
        let token: WebSocketRequestToken<Identity>
        /// 向请求调用者交付响应或错误的独立结果。
        let promise: NetworkPromise<Response>
        /// 到期时使本次请求失败的计时任务。
        let timeout: Task<Void, Never>
        /// 执行调用方发送闭包的任务；请求结束时请求取消。
        let send: Task<Void, Never>
    }
    /// 当前请求配对代次，每次 invalidate 重新生成。
    private var generation = UUID()
    /// 按业务身份索引的未完成请求；完成、取消或失效时移除。
    private var pending: [Identity: Pending] = [:]
    /// 控制请求超时的可注入等待机制。
    private let clock: any NetworkClock
    /// 创建空的请求配对器，并保存请求超时使用的时钟。
    public init(clock: any NetworkClock = SystemNetworkClock()) { self.clock = clock }

    /// 先注册响应等待，再调用 send，使快速响应也能正确配对。
    ///
    /// 结束等待时移除登记并请求取消发送及计时任务；不能撤销已经产生的网络副作用。
    ///
    /// - Parameters:
    ///   - identity: 同一时刻不得重复登记的业务身份。
    ///   - timeout: 包含发送等待在内的响应超时秒数，默认 15，须为有限值且满足 (0, 86400]。
    ///   - send: 为本次请求执行一次的异步发送闭包，须将 token 与实际协议请求关联并响应取消。
    /// - Returns: 首个匹配完整 token 的响应。
    /// - Throws: 重复身份、无效超时、响应超时、代次失效、取消或发送闭包的原始错误。
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

    /// 匹配代次、身份和 nonce 后完成请求并取消其附属任务；无法匹配时返回 false。
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
    /// 使仍匹配当前登记的请求失败，并取消超时及发送任务。
    private func fail(_ token: WebSocketRequestToken<Identity>, error: any Error) {
        guard let item = pending[token.identity], item.token == token else { return }
        item.promise.resolve(.failure(error)); remove(token)
    }
    /// 移除指定 token 对应的请求并取消附属任务；不影响同身份的新请求。
    private func remove(_ token: WebSocketRequestToken<Identity>) {
        guard let item = pending[token.identity], item.token == token else { return }
        pending.removeValue(forKey: token.identity); item.timeout.cancel(); item.send.cancel()
    }
    /// 以 shutdown 结束所有未完成请求，并取消超时与发送任务。
    deinit {
        for item in pending.values {
            item.promise.resolve(.failure(WebSocketError.shutdown)); item.timeout.cancel(); item.send.cancel()
        }
    }
}

/// 基于注册 token 的路由器；单次投递使用处理器快照，并发执行且不保证回调顺序。
public actor MessageRouter<Route: Hashable & Sendable, Message: Sendable> {
    public struct Token: Hashable, Sendable {
        /// 区分每次处理器注册的随机身份。
        fileprivate let id: UUID
    }
    private struct Registration: Sendable {
        /// 此注册接受的路由集合；重复路由由 Set 合并。
        let routes: Set<Route>
        /// 对匹配消息执行的异步处理器；注销不取消已取得快照的调用。
        let handler: @Sendable (Message) async -> Void
    }
    /// 按注册 token 保存的路由集合及异步处理器。
    private var handlers: [Token: Registration] = [:]
    /// 创建没有已注册处理器的路由器。
    public init() {}
    /// 保存路由集合和处理器并返回注销 token；空集合不会接收任何路由的消息。
    public func register(routes: Set<Route>, handler: @escaping @Sendable (Message) async -> Void) -> Token {
        let token = Token(id: UUID())
        handlers[token] = Registration(routes: routes, handler: handler)
        return token
    }
    /// 阻止后续投递；已取得快照的回调仍会完成，不被取消。
    public func unregister(_ token: Token) { handlers.removeValue(forKey: token) }
    /// 取得匹配处理器快照，并行调用各处理器一次并等待全部返回；不保证执行顺序。
    public func route(_ message: Message, to route: Route) async {
        let selected = handlers.values.filter { $0.routes.contains(route) }
        await withTaskGroup(of: Void.self) { group in
            for item in selected { group.addTask { await item.handler(message) } }
        }
    }
}
