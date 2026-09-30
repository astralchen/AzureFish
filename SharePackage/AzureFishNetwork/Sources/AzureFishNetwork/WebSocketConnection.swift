import Foundation

/// 内存队列的发送收据；成功只表示传输接受了消息，不表示业务 ACK。
public struct WebSocketSendReceipt: Sendable {
    /// 本次入队生成的唯一身份，可与发送诊断事件关联。
    public let id: UUID
    /// 连接拥有的单次发送结果；等待者取消不会移除队列条目。
    fileprivate let result: NetworkPromise<Void>
    /// 等待提交结果；取消等待不撤销已入队的数据。
    public func wait() async throws { try await result.value() }
}

/// 隔离连接代次、收发队列和订阅生命周期的 WebSocket 连接。
///
/// 调用方应在结束使用时调用 shutdown。disconnect 保留对象，可再次 connect。
public actor WebSocketConnection {
    public typealias TransportFactory = @Sendable () -> any WebSocketTransport
    public typealias HandshakeProvider = @Sendable () async throws -> WebSocketHandshake
    /// 创建连接时校验并保存的容量、超时与重连策略快照。
    private let configuration: WebSocketConfiguration
    /// 为每次握手创建独立传输实例的工厂。
    private let factory: TransportFactory
    /// 每次握手时异步获取地址和最新请求头的提供器。
    private let handshake: HandshakeProvider
    /// 供握手超时、心跳和重连退避使用的可注入时钟。
    private let clock: any NetworkClock
    /// 提供重连抖动系数的闭包；取值被限制在 0～1，非有限值按 0.5 处理。
    private let random: @Sendable () -> Double
    /// 当前连接状态，初始为 disconnected；shutdown 为终态。
    private var state: WebSocketState = .disconnected
    /// 每次启动握手或停止连接时递增的代次，用于拒绝迟到结果。
    private var generation: UInt64 = 0
    /// 当前握手尝试身份；nil 表示没有可接收结果的尝试。
    private var attempt: UUID?
    /// 当前代次的传输实例；停止或失败后移交关闭流程。
    private var transport: (any WebSocketTransport)?
    /// 共享握手及退避任务；nil 表示没有正在等待的握手。
    private var opening: Task<Void, Never>?
    /// 当前代次的单一接收循环任务。
    private var receiving: Task<Void, Never>?
    /// 已启用心跳时的周期 ping 任务；nil 表示未启动。
    private var heartbeat: Task<Void, Never>?
    /// 串行提交发送队列的任务，避免并行消费队列。
    private var draining: Task<Void, Never>?
    /// 等待共享握手结果的独立调用者，按等待身份索引。
    private var waiters: [UUID: NetworkPromise<Void>] = [:]
    /// 状态流订阅；每个订阅只保留最新状态。
    private var states: [UUID: AsyncStream<WebSocketState>.Continuation] = [:]
    /// 应用消息广播订阅；每个订阅独立受接收缓冲上限约束。
    private var subscribers: [UUID: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation] = [:]
    /// 发送诊断流订阅；缓冲满时允许丢弃旧事件。
    private var events: [UUID: AsyncStream<WebSocketEvent>.Continuation] = [:]
    /// 没有订阅者时按到达顺序暂存的消息，首个订阅者消费后清空。
    private var buffered: [WebSocketMessage] = []
    /// 订阅前缓冲是否溢出；下一个消息订阅以 receiveOverflow 结束并清除此标记。
    private var gap = false
    private struct Entry: Sendable {
        /// 发送条目的唯一身份，用于配对收据和诊断事件。
        let id: UUID
        /// 尚待提交的消息正文，仅保存在内存队列。
        let message: WebSocketMessage
        /// 该条目独立的完成结果，提交成功或失败时确定。
        let result: NetworkPromise<Void>
    }
    /// 尚未提交的发送条目，按入队顺序处理，不跨进程保存。
    private var queue: [Entry] = []
    /// 尚未提交条目的正文总字节数，不计入 inFlight。
    private var queuedBytes = 0
    /// 已从队列取出但尚未确认提交结果的条目；断线时报告 deliveryUncertain。
    private var inFlight: Entry?

    /// 校验配置并保存传输工厂与握手提供器；创建后仍处于未连接状态。
    ///
    /// - Throws: 配置的时间、容量或重连次数无效时抛出 invalidConfiguration。
    public init(configuration: WebSocketConfiguration = .init(), clock: any NetworkClock = SystemNetworkClock(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport() },
                handshake: @escaping HandshakeProvider) throws {
        try configuration.validate()
        self.configuration = configuration; self.clock = clock; self.random = random
        self.factory = transportFactory; self.handshake = handshake
    }

    /// 读取时的连接状态快照；后续变化通过 stateChanges 订阅。
    public var currentState: WebSocketState { state }

    /// 共享正在进行的握手。取消当前调用只取消其等待，不关闭连接。
    public func connect() async throws {
        try Task.checkCancellation()
        guard state != .shutdown else { throw WebSocketError.shutdown }
        if state == .connected { return }
        let id = UUID(), promise = NetworkPromise<Void>()
        waiters[id] = promise
        if opening == nil { launch(retry: nil) }
        defer { waiters.removeValue(forKey: id) }
        try await promise.value()
    }

    /// 停止传输并清空队列和消息订阅；状态订阅仍然有效。
    public func disconnect() async { await stop(terminal: false) }

    /// 永久关闭连接及所有订阅，之后 connect 和 enqueue 都失败。
    public func shutdown() async { await stop(terminal: true) }

    /// 创建独立状态订阅并立即提交当前状态，只缓冲最新一项；shutdown 后结束。
    public func stateChanges() -> AsyncStream<WebSocketState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WebSocketState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(state)
        if state == .shutdown { continuation.finish() }
        else {
            states[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeState(id) } }
        }
        return stream
    }

    /// 创建独立广播订阅；缓存满时终止该订阅并报告 receiveOverflow。
    ///
    /// 无订阅期间的有界缓存只交付给随后首个订阅者；若该缓存已溢出，首个订阅以缺口错误结束。
    /// disconnect 结束现有消息订阅；shutdown 后新订阅立即以 shutdown 错误结束。
    public func messages() -> AsyncThrowingStream<WebSocketMessage, any Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream(bufferingPolicy: .bufferingOldest(configuration.receiveBuffer))
        if state == .shutdown { continuation.finish(throwing: WebSocketError.shutdown); return stream }
        if gap {
            gap = false; buffered.removeAll()
            continuation.finish(throwing: WebSocketError.receiveOverflow)
            return stream
        }
        if subscribers.isEmpty {
            for message in buffered { continuation.yield(message) }
            buffered.removeAll()
        }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// 诊断事件可合并丢弃；需要逐条发送结论时应等待 enqueue 返回的收据。
    public func sendEvents() -> AsyncStream<WebSocketEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WebSocketEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        if state == .shutdown { continuation.finish() }
        else {
            events[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeEvent(id) } }
        }
        return stream
    }

    /// 将消息放入有界内存队列；不会主动连接，也不提供持久 outbox。
    public func enqueue(_ message: WebSocketMessage) throws -> WebSocketSendReceipt {
        guard state != .shutdown else { throw WebSocketError.shutdown }
        guard message.byteCount <= configuration.maximumMessageBytes else { throw WebSocketError.messageTooLarge }
        guard queue.count < configuration.maximumQueuedMessages,
              message.byteCount <= configuration.maximumQueuedBytes - queuedBytes else { throw WebSocketError.queueFull }
        let entry = Entry(id: UUID(), message: message, result: NetworkPromise())
        queue.append(entry); queuedBytes += message.byteCount
        startDrain()
        return WebSocketSendReceipt(id: entry.id, result: entry.result)
    }

    /// 仅在已连接时发送；返回值不代表服务器已经处理业务消息。
    public func send(_ message: WebSocketMessage) async throws {
        guard state == .connected else { throw WebSocketError.notConnected }
        let receipt = try enqueue(message)
        do { try await receipt.wait() }
        catch is CancellationError {
            if cancelSend(receipt.id) { throw CancellationError() }
            throw WebSocketError.deliveryUncertain
        }
    }

    /// 递增代次并启动一次握手；重连时先等待带抖动的指数退避。
    private func launch(retry: Int?) {
        generation &+= 1
        let id = UUID(), currentGeneration = generation
        attempt = id
        setState(retry.map { .reconnecting(attempt: $0) } ?? .connecting)
        let transport = factory()
        self.transport = transport
        let config = configuration, clock = clock, handshake = handshake
        let draw = random()
        let jitter = draw.isFinite ? min(1, max(0, draw)) : 0.5
        let delay = retry.map { min(config.reconnectMaximumDelay, config.reconnectBaseDelay * pow(2, Double($0 - 1))) * jitter } ?? 0
        opening = Task { [weak self] in
            let started = NetworkDiagnostics.live.startTime()
            do {
                if delay > 0 { try await clock.sleep(seconds: delay) }
                try Task.checkCancellation()
                try await webSocketTimeout(seconds: config.handshakeTimeout, clock: clock, error: .handshakeTimeout) {
                    let request = try await handshake()
                    try Task.checkCancellation()
                    try await transport.connect(request, maximumMessageBytes: config.maximumMessageBytes)
                }
                try Task.checkCancellation()
                NetworkDiagnostics.live.log("ws generation=\(currentGeneration) handshake_ms=\(NetworkDiagnostics.elapsedMilliseconds(since: started)) outcome=opened")
                await self?.opened(id, generation: currentGeneration, transport: transport)
            } catch {
                NetworkDiagnostics.live.log("ws generation=\(currentGeneration) handshake_ms=\(NetworkDiagnostics.elapsedMilliseconds(since: started)) outcome=failed")
                await transport.close()
                await self?.openingFailed(id, generation: currentGeneration, retry: retry, error: WebSocketError.sanitize(error))
            }
        }
    }

    /// 接纳当前代次的握手结果，恢复连接等待者并启动接收、心跳和发送循环。
    private func opened(_ id: UUID, generation: UInt64, transport: any WebSocketTransport) {
        guard attempt == id, self.generation == generation else { return }
        opening = nil; setState(.connected)
        resolveWaiters(.success(()))
        let clock = clock, config = configuration
        receiving = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await transport.receive()
                    try Task.checkCancellation()
                    await self?.received(message, attempt: id)
                }
            } catch { await self?.failed(id, error: WebSocketError.sanitize(error)) }
        }
        if let interval = config.pingInterval {
            heartbeat = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        try await clock.sleep(seconds: interval)
                        try Task.checkCancellation()
                        try await webSocketTimeout(seconds: config.pongTimeout, clock: clock, error: .pongTimeout) { try await transport.ping() }
                    }
                } catch { await self?.failed(id, error: WebSocketError.sanitize(error)) }
            }
        }
        startDrain()
    }

    /// 处理当前握手失败；重连尝试尚有预算且错误可重试时安排下一次尝试。
    private func openingFailed(_ id: UUID, generation: UInt64, retry: Int?, error: WebSocketError) {
        guard attempt == id, self.generation == generation else { return }
        opening = nil; transport = nil; attempt = nil
        if let retry, error.retryable || error == .handshakeTimeout {
            if retry < configuration.reconnectAttempts { launch(retry: retry + 1); return }
            terminate(.reconnectExhausted)
        } else { terminate(error) }
    }

    /// 结束当前连接的收发任务；已提交消息标记送达不确定，再按策略重连或终止。
    private func failed(_ id: UUID, error: WebSocketError) {
        guard attempt == id, state == .connected else { return }
        attempt = nil
        receiving?.cancel(); receiving = nil; heartbeat?.cancel(); heartbeat = nil
        draining?.cancel(); draining = nil
        if let entry = inFlight { finish(entry, error: .deliveryUncertain); inFlight = nil }
        let old = transport; transport = nil
        Task { await old?.close() }
        if error.retryable && configuration.reconnectAttempts > 0 { launch(retry: 1) }
        else { terminate(error) }
    }

    /// 发布失败状态，使待连接及待发送操作失败，并终止消息订阅。
    private func terminate(_ error: WebSocketError) {
        setState(.failed(error)); resolveWaiters(.failure(error))
        for entry in queue { finish(entry, error: error) }
        queue.removeAll(); queuedBytes = 0
        for continuation in subscribers.values { continuation.finish(throwing: error) }
        subscribers.removeAll(); buffered.removeAll(); gap = false
    }

    /// 分发当前连接的消息；无订阅者时暂存，单个订阅溢出时只终止该订阅。
    private func received(_ message: WebSocketMessage, attempt: UUID) {
        guard self.attempt == attempt, state == .connected else { return }
        guard message.byteCount <= configuration.maximumMessageBytes else { failed(attempt, error: .messageTooLarge); return }
        NetworkDiagnostics.live.log("ws generation=\(generation) receivedBytes=\(message.byteCount)")
        if subscribers.isEmpty {
            if buffered.count < configuration.receiveBuffer && !gap { buffered.append(message) }
            else { gap = true; buffered.removeAll() }
        } else {
            for (id, continuation) in subscribers {
                if case .dropped = continuation.yield(message) {
                    continuation.finish(throwing: WebSocketError.receiveOverflow)
                    subscribers.removeValue(forKey: id)
                }
            }
        }
    }

    /// 连接可用且队列非空时启动唯一发送循环，为每条消息设置提交超时。
    private func startDrain() {
        guard state == .connected, draining == nil, let id = attempt, let transport, !queue.isEmpty else { return }
        let clock = clock, timeout = configuration.sendTimeout
        draining = Task { [weak self] in
            while !Task.isCancelled, let entry = await self?.nextSend(id) {
                let started = NetworkDiagnostics.live.startTime()
                do {
                    try await webSocketTimeout(seconds: timeout, clock: clock, error: .sendTimeout) { try await transport.send(entry.message) }
                    NetworkDiagnostics.live.log("ws sentBytes=\(entry.message.byteCount) send_ms=\(NetworkDiagnostics.elapsedMilliseconds(since: started))")
                    await self?.sent(entry, attempt: id)
                } catch { await self?.failed(id, error: WebSocketError.sanitize(error)); return }
            }
            await self?.drainFinished(id)
        }
    }
    /// 取出当前尝试的队首条目并标记为 inFlight；尝试失效或队列为空时返回 nil。
    private func nextSend(_ id: UUID) -> Entry? {
        guard attempt == id, !queue.isEmpty else { return nil }
        let entry = queue.removeFirst(); queuedBytes -= entry.message.byteCount
        inFlight = entry
        return entry
    }
    /// 仅接受当前尝试的在途结果，完成收据并广播 sent 事件。
    private func sent(_ entry: Entry, attempt: UUID) {
        guard self.attempt == attempt, inFlight?.id == entry.id else { return }
        inFlight = nil; entry.result.resolve(.success(()))
        for continuation in events.values { continuation.yield(.sent(entry.id)) }
    }
    /// 清理当前尝试的发送任务，并检查挂起期间是否又有消息入队。
    private func drainFinished(_ id: UUID) {
        guard attempt == id else { return }
        draining = nil; startDrain()
    }
    /// 移除尚未提交的指定条目并取消其收据；已提交或已移除时返回 false。
    private func cancelSend(_ id: UUID) -> Bool {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index); queuedBytes -= entry.message.byteCount
            entry.result.resolve(.failure(CancellationError()))
            return true
        }
        return false
    }
    /// 以指定错误完成发送收据，并广播对应 sendFailed 事件。
    private func finish(_ entry: Entry, error: WebSocketError) {
        entry.result.resolve(.failure(error))
        for continuation in events.values { continuation.yield(.sendFailed(entry.id, error)) }
    }
    /// 取消连接任务并清空收发数据；terminal 为 true 时同时结束状态及发送事件订阅。
    private func stop(terminal: Bool) async {
        guard state != .shutdown else { return }
        generation &+= 1; attempt = nil
        opening?.cancel(); opening = nil; receiving?.cancel(); receiving = nil
        heartbeat?.cancel(); heartbeat = nil; draining?.cancel(); draining = nil
        let old = transport; transport = nil
        resolveWaiters(.failure(terminal ? WebSocketError.shutdown : WebSocketError.notConnected))
        if let inFlight { finish(inFlight, error: .deliveryUncertain) }; inFlight = nil
        for entry in queue { finish(entry, error: terminal ? .shutdown : .notConnected) }
        queue.removeAll(); queuedBytes = 0; buffered.removeAll(); gap = false
        for continuation in subscribers.values { continuation.finish() }; subscribers.removeAll()
        setState(terminal ? .shutdown : .disconnected)
        if terminal {
            for continuation in states.values { continuation.finish() }; states.removeAll()
            for continuation in events.values { continuation.finish() }; events.removeAll()
        }
        await old?.close()
    }
    /// 以同一结果恢复全部握手等待者并清空登记。
    private func resolveWaiters(_ result: Result<Void, any Error>) {
        for promise in waiters.values { promise.resolve(result) }; waiters.removeAll()
    }
    /// 保存并广播连接状态，同时输出脱敏状态诊断。
    private func setState(_ state: WebSocketState) {
        self.state = state
        NetworkDiagnostics.live.log("ws generation=\(generation) state=\(state)")
        for continuation in states.values { continuation.yield(state) }
    }
    /// 移除已结束的状态订阅。
    private func removeState(_ id: UUID) { states.removeValue(forKey: id) }
    /// 移除已结束的应用消息订阅。
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    /// 移除已结束的发送诊断订阅。
    private func removeEvent(_ id: UUID) { events.removeValue(forKey: id) }
    /// 取消所属任务，异步关闭传输并结束等待者与订阅；在途发送报告送达不确定。
    deinit {
        opening?.cancel(); receiving?.cancel(); heartbeat?.cancel(); draining?.cancel()
        let transport = transport
        Task { await transport?.close() }
        for promise in waiters.values { promise.resolve(.failure(WebSocketError.shutdown)) }
        for entry in queue { entry.result.resolve(.failure(WebSocketError.shutdown)) }
        inFlight?.result.resolve(.failure(WebSocketError.deliveryUncertain))
        for continuation in subscribers.values { continuation.finish() }
        for continuation in states.values { continuation.finish() }
        for continuation in events.values { continuation.finish() }
    }
}
