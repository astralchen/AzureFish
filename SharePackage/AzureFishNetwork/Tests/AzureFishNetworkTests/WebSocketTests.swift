import Foundation
import Testing
@testable import AzureFishNetwork
import AzureFishNetworkTestSupport

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    throw WebSocketError.requestTimeout
}

@Suite("WebSocket 生命周期与边界", .timeLimit(.minutes(1)))
struct WebSocketTests {
    private func connection(_ transports: [MockWebSocketTransport], configuration: WebSocketConfiguration = .init(),
                            clock: any NetworkClock = SystemNetworkClock()) throws -> (WebSocketConnection, MockWebSocketFactory) {
        let factory = MockWebSocketFactory(transports)
        return (try WebSocketConnection(configuration: configuration, clock: clock, random: { 0 }, transportFactory: factory.make) {
            WebSocketHandshake(url: URL(string: "wss://example.invalid/live")!)
        }, factory)
    }

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

    @Test func releasingConnectionClosesTransport() async throws {
        let transport = MockWebSocketTransport()
        var socket: WebSocketConnection? = try connection([transport]).0
        let probe = WeakSocket(try #require(socket))
        try await socket?.connect()
        socket = nil
        try await eventually { probe.value == nil }
        try await eventually { await transport.closeCount > 0 }
    }

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
    var value: WebSocketRequestToken<String>?
    func set(_ value: WebSocketRequestToken<String>) { self.value = value }
}
private actor Counter { var value = 0; func add(_ amount: Int) { value += amount } }

private final class WeakSocket: @unchecked Sendable {
    weak var value: WebSocketConnection?
    init(_ value: WebSocketConnection) { self.value = value }
}
private actor RouteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
