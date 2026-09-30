import Foundation
import Testing
@testable import AzureFishNetwork
import AzureFishNetworkTestSupport

/// 以 2 毫秒间隔最多检查条件 1000 次；仍未满足时抛出 requestTimeout。
private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    throw WebSocketError.requestTimeout
}

@Suite("WebSocket 生命周期与边界", .timeLimit(.minutes(1)))
struct WebSocketTests {
    /// 创建使用预设模拟传输、零抖动及虚构握手地址的连接，返回连接与工厂。
    private func connection(_ transports: [MockWebSocketTransport], configuration: WebSocketConfiguration = .init(),
                            clock: any NetworkClock = SystemNetworkClock()) throws -> (WebSocketConnection, MockWebSocketFactory) {
        let factory = MockWebSocketFactory(transports)
        return (try WebSocketConnection(configuration: configuration, clock: clock, random: { 0 }, transportFactory: factory.make) {
            WebSocketHandshake(url: URL(string: "wss://example.invalid/live")!)
        }, factory)
    }

    /// 验证握手共享、独立等待取消及断开后的再次连接。
    @Test func sharedHandshakeCancellationAndRestart() async throws {
        let first = MockWebSocketTransport(automaticOpen: false), second = MockWebSocketTransport()
        let (socket, factory) = try connection([first, second])
        let one = Task { try await socket.connect() }, two = Task { try await socket.connect() }
        try await eventually { await first.handshakes.count == 1 }
        one.cancel()
        await #expect(throws: CancellationError.self) { try await one.value }
        #expect(await first.closeCount == 0)
        await first.completeOpen(); try await two.value
        #expect(factory.count == 1)
        await socket.disconnect(); try await socket.connect()
        await first.push(.failure(WebSocketError.closed(code: 1008)))
        #expect(await socket.currentState == .connected)
        await socket.shutdown()
        await #expect(throws: WebSocketError.shutdown) { try await socket.connect() }
    }

    /// 验证初次握手超时后不会自动套用断线重连策略。
    @Test func handshakeTimeoutAndNoInitialRetry() async throws {
        let clock = TestNetworkClock(), transport = MockWebSocketTransport(automaticOpen: false)
        let (socket, factory) = try connection([transport], clock: clock)
        let task = Task { try await socket.connect() }
        try await eventually { let a = await clock.pendingCount; let b = await transport.handshakes.count; return a == 1 && b == 1 }
        await clock.advance(by: 15)
        await #expect(throws: WebSocketError.handshakeTimeout) { try await task.value }
        #expect(factory.count == 1)
        #expect(await transport.closeCount > 0)
        await socket.shutdown()
    }

    /// 验证发送队列遵守字节上限且重连只保留未提交条目。
    @Test func queuesBoundBytesAndKeepOnlyUnsubmittedAcrossReconnect() async throws {
        var config = WebSocketConfiguration(); config.maximumQueuedMessages = 2; config.maximumQueuedBytes = 4
        let first = MockWebSocketTransport(automaticSend: false), second = MockWebSocketTransport()
        let (socket, _) = try connection([first, second], configuration: config)
        let a = try await socket.enqueue(.text("aa")), b = try await socket.enqueue(.text("bb"))
        await #expect(throws: WebSocketError.queueFull) { try await socket.enqueue(.text("c")) }
        try await socket.connect()
        try await eventually { await first.sent.count == 1 }
        await first.completeSend(.failure(WebSocketError.transport(code: URLError.networkConnectionLost.rawValue)))
        await #expect(throws: WebSocketError.deliveryUncertain) { try await a.wait() }
        try await b.wait()
        #expect(await second.sent == [.text("bb")])
        await socket.disconnect()
        let abandoned = try await socket.enqueue(.text("a"))
        await socket.disconnect()
        await #expect(throws: WebSocketError.notConnected) { try await abandoned.wait() }
        await socket.shutdown()
    }

    /// 验证发送超时报告送达不确定且策略关闭不自动重试。
    @Test func sendTimeoutIsUncertainAndPolicyCloseNeverRetries() async throws {
        let clock = TestNetworkClock(), transport = MockWebSocketTransport(automaticSend: false)
        var config = WebSocketConfiguration(); config.reconnectAttempts = 0
        let (socket, _) = try connection([transport], configuration: config, clock: clock)
        try await socket.connect()
        let receipt = try await socket.enqueue(.text("once"))
        try await eventually { let a = await transport.sent.count; let b = await clock.pendingCount; return a == 1 && b == 1 }
        await clock.advance(by: 15)
        await #expect(throws: WebSocketError.deliveryUncertain) { try await receipt.wait() }
        await socket.shutdown()
        let policy = MockWebSocketTransport()
        let (other, factory) = try connection([policy])
        try await other.connect(); await policy.push(.failure(WebSocketError.closed(code: 1008)))
        try await eventually { await other.currentState == .failed(.closed(code: 1008)) }
        #expect(factory.count == 1)
        await other.shutdown()
    }

    /// 验证pong 超时触发有界重连且预算耗尽后结束。
    @Test func pongTimeoutAndReconnectExhaustion() async throws {
        let clock = TestNetworkClock(), first = MockWebSocketTransport(automaticPong: false)
        let second = MockWebSocketTransport(automaticOpen: false), third = MockWebSocketTransport(automaticOpen: false)
        var config = WebSocketConfiguration(); config.pingInterval = 25; config.reconnectAttempts = 2
        let (socket, factory) = try connection([first, second, third], configuration: config, clock: clock)
        try await socket.connect()
        try await eventually { await clock.pendingCount == 1 }
        await clock.advance(by: 25)
        try await eventually { let a = await first.pingCount; let b = await clock.pendingCount; return a == 1 && b == 1 }
        await clock.advance(by: 10)
        try await eventually { await second.handshakes.count == 1 }
        await second.completeOpen(.failure(WebSocketError.transportFailed))
        try await eventually { await third.handshakes.count == 1 }
        await third.completeOpen(.failure(WebSocketError.transportFailed))
        try await eventually { await socket.currentState == .failed(.reconnectExhausted) }
        #expect(factory.count == 3)
        await socket.shutdown()
    }

    /// 验证慢订阅者溢出及订阅前接收缺口被明确报告。
    @Test func slowSubscriberAndPresubscriptionGapAreExplicit() async throws {
        var config = WebSocketConfiguration(); config.receiveBuffer = 1
        let transport = MockWebSocketTransport()
        let (socket, _) = try connection([transport], configuration: config)
        let stream = await socket.messages()
        try await socket.connect()
        await transport.push(.success(.text("one"))); await transport.push(.success(.text("two")))
        var iterator = stream.makeAsyncIterator()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(try await iterator.next() == .text("one"))
        await #expect(throws: WebSocketError.receiveOverflow) { try await iterator.next() }
        await transport.push(.success(.text("three"))); await transport.push(.success(.text("four")))
        try await Task.sleep(nanoseconds: 20_000_000)
        var next = await socket.messages().makeAsyncIterator()
        await #expect(throws: WebSocketError.receiveOverflow) { try await next.next() }
        await socket.shutdown()
    }

    /// 验证收发消息均遵守字节上限。
    @Test func inboundAndOutboundSizeLimits() async throws {
        var config = WebSocketConfiguration(); config.maximumMessageBytes = 2
        let transport = MockWebSocketTransport()
        let (socket, _) = try connection([transport], configuration: config)
        await #expect(throws: WebSocketError.messageTooLarge) { try await socket.enqueue(.text("中")) }
        try await socket.connect()
        await transport.push(.success(.binary(Data(repeating: 0, count: 3))))
        try await eventually { await socket.currentState == .failed(.messageTooLarge) }
        await socket.shutdown()
    }

    /// 验证释放连接对象时请求关闭底层传输。
    @Test func releasingConnectionClosesTransport() async throws {
        let transport = MockWebSocketTransport()
        var socket: WebSocketConnection? = try connection([transport]).0
        let probe = WeakSocket(try #require(socket))
        try await socket?.connect()
        socket = nil
        try await eventually { probe.value == nil }
        try await eventually { await transport.closeCount > 0 }
    }

    /// 验证已提交发送取消报告不确定且收据等待者互相独立。
    @Test func submittedSendCancellationIsUncertainAndReceiptWaitersAreIndependent() async throws {
        let transport = MockWebSocketTransport(automaticSend: false)
        let (socket, _) = try connection([transport])
        try await socket.connect()
        let sending = Task { try await socket.send(.text("once")) }
        try await eventually { await transport.sent.count == 1 }
        sending.cancel()
        await #expect(throws: WebSocketError.deliveryUncertain) { try await sending.value }
        await transport.completeSend()
        let receipt = try await socket.enqueue(.text("shared"))
        let cancelled = Task { try await receipt.wait() }, other = Task { try await receipt.wait() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await eventually { await transport.sent.count == 2 }
        await transport.completeSend()
        try await other.value
        await socket.shutdown()
    }

    /// 验证注销路由不取消已取得快照的回调。
    @Test func routerUnregisterDoesNotCancelSnapshotAlreadyRunning() async throws {
        let router = MessageRouter<String, Int>(), gate = RouteGate(), counter = Counter()
        let token = await router.register(routes: ["route"]) { value in
            await counter.add(value); await gate.wait(); await counter.add(value)
        }
        let delivery = Task { await router.route(1, to: "route") }
        try await eventually { await counter.value == 1 }
        await router.unregister(token)
        await router.route(10, to: "route")
        await gate.release(); await delivery.value
        #expect(await counter.value == 2)
    }

    /// 验证请求配对覆盖快速响应、重复身份、取消及旧 token。
    @Test func brokerFastResponseDuplicateCancellationAndOldToken() async throws {
        let broker = WebSocketRequestBroker<String, Int>(), tokens = TokenBox()
        let answer = try await broker.request(identity: "fast") { token in _ = await broker.resolve(7, for: token) }
        #expect(answer == 7)
        let pending = Task { try await broker.request(identity: "same") { await tokens.set($0) } }
        try await eventually { await tokens.value != nil }
        await #expect(throws: WebSocketError.duplicateRequest) { try await broker.request(identity: "same") { _ in } }
        let old = try #require(await tokens.value)
        await broker.invalidate()
        await #expect(throws: WebSocketError.staleGeneration) { try await pending.value }
        #expect(await broker.resolve(9, for: old) == false)
        let cancelled = Task { try await broker.request(identity: "cancel") { _ in } }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    /// 验证请求配对超时和路由注销快照语义。
    @Test func brokerTimeoutAndRouterUnregisterSnapshot() async throws {
        let clock = TestNetworkClock(), broker = WebSocketRequestBroker<String, Int>(clock: TestNetworkClock())
        await broker.invalidate()
        let timed = WebSocketRequestBroker<String, Int>(clock: clock)
        let pending = Task { try await timed.request(identity: "timeout") { _ in } }
        try await eventually { await clock.pendingCount == 1 }
        await clock.advance(by: 15)
        await #expect(throws: WebSocketError.requestTimeout) { try await pending.value }
        let router = MessageRouter<String, Int>(), counter = Counter()
        let token = await router.register(routes: ["a"]) { value in await counter.add(value) }
        await router.route(2, to: "a"); await router.unregister(token); await router.route(4, to: "a")
        #expect(await counter.value == 2)
    }
}

private actor TokenBox {
    /// 最近登记的请求 token；nil 表示尚未登记。
    var value: WebSocketRequestToken<String>?
    /// 保存请求 token，供测试稍后注入配对响应。
    func set(_ value: WebSocketRequestToken<String>) { self.value = value }
}
private actor Counter {
    /// 异步回调累计值，初始为 0。
    var value = 0;
    /// 将指定数值累加到测试计数器。
    func add(_ amount: Int) { value += amount } }

private final class WeakSocket: @unchecked Sendable {
    /// 对连接的弱引用，用于验证连接释放而不延长其生命周期。
    weak var value: WebSocketConnection?
    /// 保存连接的弱引用，不取得持有权。
    init(_ value: WebSocketConnection) { self.value = value }
}
private actor RouteGate {
    /// 当前路由处理器等待测试释放的 continuation，仅支持一个等待者。
    private var continuation: CheckedContinuation<Void, Never>?
    /// 屏障是否已被测试释放；释放后 wait 直接返回。
    private var released = false
    /// 等待测试显式释放路由处理器；此屏障不单独处理任务取消。
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    /// 标记已释放并恢复当前等待者，清除 continuation。
    func release() { released = true; continuation?.resume(); continuation = nil }
}
