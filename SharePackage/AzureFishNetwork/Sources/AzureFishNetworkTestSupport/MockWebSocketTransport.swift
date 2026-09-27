import Foundation
import AzureFishNetwork

/// 可逐步释放握手、发送和 pong 的测试传输，不建立网络连接。
public actor MockWebSocketTransport: WebSocketTransport {
    public var automaticOpen: Bool
    public var automaticSend: Bool
    public var automaticPong: Bool
    public private(set) var handshakes: [WebSocketHandshake] = []
    public private(set) var sent: [WebSocketMessage] = []
    public private(set) var pingCount = 0
    public private(set) var closeCount = 0
    private var opening: CheckedContinuation<Void, any Error>?
    private var sending: CheckedContinuation<Void, any Error>?
    private var pong: CheckedContinuation<Void, any Error>?
    private var receiver: CheckedContinuation<WebSocketMessage, any Error>?
    private var incoming: [Result<WebSocketMessage, any Error>] = []
    private var closed = false

    public init(automaticOpen: Bool = true, automaticSend: Bool = true, automaticPong: Bool = true) {
        self.automaticOpen = automaticOpen; self.automaticSend = automaticSend; self.automaticPong = automaticPong
    }
    public func connect(_ handshake: WebSocketHandshake, maximumMessageBytes: Int) async throws {
        guard !closed else { throw WebSocketError.shutdown }
        handshakes.append(handshake)
        if !automaticOpen { try await withCheckedThrowingContinuation { opening = $0 } }
    }
    public func completeOpen(_ result: Result<Void, any Error> = .success(())) { opening?.resume(with: result); opening = nil }
    public func send(_ message: WebSocketMessage) async throws {
        guard !closed else { throw WebSocketError.notConnected }
        sent.append(message)
        if !automaticSend { try await withCheckedThrowingContinuation { sending = $0 } }
    }
    public func completeSend(_ result: Result<Void, any Error> = .success(())) { sending?.resume(with: result); sending = nil }
    public func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        guard !closed else { throw WebSocketError.notConnected }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    public func push(_ result: Result<WebSocketMessage, any Error>) {
        if let receiver { self.receiver = nil; receiver.resume(with: result) }
        else { incoming.append(result) }
    }
    public func ping() async throws {
        guard !closed else { throw WebSocketError.notConnected }
        pingCount += 1
        if !automaticPong { try await withCheckedThrowingContinuation { pong = $0 } }
    }
    public func completePong(_ result: Result<Void, any Error> = .success(())) { pong?.resume(with: result); pong = nil }
    public func close() async {
        closed = true; closeCount += 1
        completeOpen(.failure(CancellationError())); completeSend(.failure(CancellationError())); completePong(.failure(CancellationError()))
        receiver?.resume(throwing: CancellationError()); receiver = nil
    }
}

/// 按顺序分配独立传输实例，便于验证旧代次隔离。
public final class MockWebSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var available: [MockWebSocketTransport]
    private var used: [MockWebSocketTransport] = []
    public init(_ transports: [MockWebSocketTransport]) { available = transports }
    public func make() -> any WebSocketTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = available.isEmpty ? MockWebSocketTransport() : available.removeFirst()
        used.append(transport)
        return transport
    }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return used.count }
}

/// 由测试显式推进的时钟；取消会移除对应等待者。
public actor TestNetworkClock: NetworkClock {
    private struct Waiter {
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var now: TimeInterval = 0
    private var waiters: [UUID: Waiter] = [:]
    public init() {}
    public var pendingCount: Int { waiters.count }
    public func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if seconds <= 0 { continuation.resume() }
                else { waiters[id] = Waiter(deadline: now + seconds, continuation: continuation) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    public func advance(by seconds: TimeInterval) {
        now += max(0, seconds)
        for (id, waiter) in waiters where waiter.deadline <= now {
            waiters.removeValue(forKey: id); waiter.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}
