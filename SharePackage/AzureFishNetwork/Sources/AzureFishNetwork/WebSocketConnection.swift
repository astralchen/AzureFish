import Foundation

/// 内存队列的发送收据；成功只表示传输接受了消息，不表示业务 ACK。
public struct WebSocketSendReceipt: Sendable {
    public let id: UUID
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
    private let configuration: WebSocketConfiguration
    private let factory: TransportFactory
    private let handshake: HandshakeProvider
    private let clock: any NetworkClock
    private let random: @Sendable () -> Double
    private var state: WebSocketState = .disconnected
    private var generation: UInt64 = 0
    private var attempt: UUID?
    private var transport: (any WebSocketTransport)?
    private var opening: Task<Void, Never>?
    private var receiving: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var draining: Task<Void, Never>?
    private var waiters: [UUID: NetworkPromise<Void>] = [:]
    private var states: [UUID: AsyncStream<WebSocketState>.Continuation] = [:]
    private var subscribers: [UUID: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation] = [:]
    private var events: [UUID: AsyncStream<WebSocketEvent>.Continuation] = [:]
    private var buffered: [WebSocketMessage] = []
    private var gap = false
    private struct Entry: Sendable {
        let id: UUID
        let message: WebSocketMessage
        let result: NetworkPromise<Void>
    }
    private var queue: [Entry] = []
    private var queuedBytes = 0
    private var inFlight: Entry?

    public init(configuration: WebSocketConfiguration = .init(), clock: any NetworkClock = SystemNetworkClock(),
                random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                transportFactory: @escaping TransportFactory = { URLSessionWebSocketTransport() },
                handshake: @escaping HandshakeProvider) throws {
        try configuration.validate()
        self.configuration = configuration; self.clock = clock; self.random = random
        self.factory = transportFactory; self.handshake = handshake
    }

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

    /// 独立广播订阅；缓存满时终止该订阅并报告 receiveOverflow。
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

    private func openingFailed(_ id: UUID, generation: UInt64, retry: Int?, error: WebSocketError) {
        guard attempt == id, self.generation == generation else { return }
        opening = nil; transport = nil; attempt = nil
        if let retry, error.retryable || error == .handshakeTimeout {
            if retry < configuration.reconnectAttempts { launch(retry: retry + 1); return }
            terminate(.reconnectExhausted)
        } else { terminate(error) }
    }

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

    private func terminate(_ error: WebSocketError) {
        setState(.failed(error)); resolveWaiters(.failure(error))
        for entry in queue { finish(entry, error: error) }
        queue.removeAll(); queuedBytes = 0
        for continuation in subscribers.values { continuation.finish(throwing: error) }
        subscribers.removeAll(); buffered.removeAll(); gap = false
    }

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
    private func nextSend(_ id: UUID) -> Entry? {
        guard attempt == id, !queue.isEmpty else { return nil }
        let entry = queue.removeFirst(); queuedBytes -= entry.message.byteCount
        inFlight = entry
        return entry
    }
    private func sent(_ entry: Entry, attempt: UUID) {
        guard self.attempt == attempt, inFlight?.id == entry.id else { return }
        inFlight = nil; entry.result.resolve(.success(()))
        for continuation in events.values { continuation.yield(.sent(entry.id)) }
    }
    private func drainFinished(_ id: UUID) {
        guard attempt == id else { return }
        draining = nil; startDrain()
    }
    private func cancelSend(_ id: UUID) -> Bool {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let entry = queue.remove(at: index); queuedBytes -= entry.message.byteCount
            entry.result.resolve(.failure(CancellationError()))
            return true
        }
        return false
    }
    private func finish(_ entry: Entry, error: WebSocketError) {
        entry.result.resolve(.failure(error))
        for continuation in events.values { continuation.yield(.sendFailed(entry.id, error)) }
    }
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
    private func resolveWaiters(_ result: Result<Void, any Error>) {
        for promise in waiters.values { promise.resolve(result) }; waiters.removeAll()
    }
    private func setState(_ state: WebSocketState) {
        self.state = state
        NetworkDiagnostics.live.log("ws generation=\(generation) state=\(state)")
        for continuation in states.values { continuation.yield(state) }
    }
    private func removeState(_ id: UUID) { states.removeValue(forKey: id) }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func removeEvent(_ id: UUID) { events.removeValue(forKey: id) }
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
