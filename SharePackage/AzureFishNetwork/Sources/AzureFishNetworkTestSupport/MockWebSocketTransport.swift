import Foundation
import AzureFishNetwork

/// 可逐步释放握手、发送和 pong 的测试传输，不建立网络连接。
public actor MockWebSocketTransport: WebSocketTransport {
    /// 是否直接完成后续握手，默认 true；false 时需调用 completeOpen 或 close。
    public var automaticOpen: Bool
    /// 是否直接完成后续发送，默认 true；false 时需调用 completeSend 或 close。
    public var automaticSend: Bool
    /// 是否直接完成后续 ping，默认 true；false 时需调用 completePong 或 close。
    public var automaticPong: Bool
    /// 按调用顺序记录的握手输入，初始为空；仅允许虚构凭据。
    public private(set) var handshakes: [WebSocketHandshake] = []
    /// 按调用顺序记录的消息，包含仍在等待 completeSend 的消息。
    public private(set) var sent: [WebSocketMessage] = []
    /// 通过连接状态检查的 ping 调用次数，初始为 0。
    public private(set) var pingCount = 0
    /// close 的累计调用次数，包含重复关闭。
    public private(set) var closeCount = 0
    /// 等待测试释放的握手 continuation；同一时间仅支持一个。
    private var opening: CheckedContinuation<Void, any Error>?
    /// 等待测试释放的发送 continuation；同一时间仅支持一个。
    private var sending: CheckedContinuation<Void, any Error>?
    /// 等待测试释放的 pong continuation；同一时间仅支持一个。
    private var pong: CheckedContinuation<Void, any Error>?
    /// 没有预存结果时的接收等待者；同一时间仅支持一个。
    private var receiver: CheckedContinuation<WebSocketMessage, any Error>?
    /// 尚未消费的注入结果，按 push 顺序供 receive 读取。
    private var incoming: [Result<WebSocketMessage, any Error>] = []
    /// 是否已关闭；关闭后不接受新的握手、发送或 ping。
    private var closed = false

    /// 配置握手、发送及 pong 是否自动完成；所有记录及计数初始为空或零。
    public init(automaticOpen: Bool = true, automaticSend: Bool = true, automaticPong: Bool = true) {
        self.automaticOpen = automaticOpen; self.automaticSend = automaticSend; self.automaticPong = automaticPong
    }
    /// 记录握手，按 automaticOpen 立即完成或等待释放；此模拟实现不校验消息上限。
    public func connect(_ handshake: WebSocketHandshake, maximumMessageBytes: Int) async throws {
        guard !closed else { throw WebSocketError.shutdown }
        handshakes.append(handshake)
        if !automaticOpen { try await withCheckedThrowingContinuation { opening = $0 } }
    }
    /// 恢复当前握手等待者并清空登记；没有等待者时忽略结果。
    public func completeOpen(_ result: Result<Void, any Error> = .success(())) { opening?.resume(with: result); opening = nil }
    /// 记录消息，按 automaticSend 立即完成或等待释放；不模拟服务端业务确认。
    public func send(_ message: WebSocketMessage) async throws {
        guard !closed else { throw WebSocketError.notConnected }
        sent.append(message)
        if !automaticSend { try await withCheckedThrowingContinuation { sending = $0 } }
    }
    /// 恢复当前发送等待者并清空登记；没有等待者时忽略结果。
    public func completeSend(_ result: Result<Void, any Error> = .success(())) { sending?.resume(with: result); sending = nil }
    /// 先消费已注入的结果，否则等待 push；仅支持一个未完成接收，取消需通过 close 释放。
    public func receive() async throws -> WebSocketMessage {
        if !incoming.isEmpty { return try incoming.removeFirst().get() }
        guard !closed else { throw WebSocketError.notConnected }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    /// 将结果交付给当前接收者；没有接收者时按到达顺序缓存。
    public func push(_ result: Result<WebSocketMessage, any Error>) {
        if let receiver { self.receiver = nil; receiver.resume(with: result) }
        else { incoming.append(result) }
    }
    /// 增加 ping 计数，并按 automaticPong 决定是否等待显式释放。
    public func ping() async throws {
        guard !closed else { throw WebSocketError.notConnected }
        pingCount += 1
        if !automaticPong { try await withCheckedThrowingContinuation { pong = $0 } }
    }
    /// 恢复当前 pong 等待者并清空登记；没有等待者时忽略结果。
    public func completePong(_ result: Result<Void, any Error> = .success(())) { pong?.resume(with: result); pong = nil }
    /// 记录关闭并以 CancellationError 释放所有当前等待者；不清除已注入的接收结果。
    public func close() async {
        closed = true; closeCount += 1
        completeOpen(.failure(CancellationError())); completeSend(.failure(CancellationError())); completePong(.failure(CancellationError()))
        receiver?.resume(throwing: CancellationError()); receiver = nil
    }
}

/// 按顺序分配独立传输实例，便于验证旧代次隔离。
public final class MockWebSocketFactory: @unchecked Sendable {
    /// 保护可用实例、已分配实例和计数读取的锁。
    private let lock = NSLock()
    /// 按提供顺序等待分配的模拟传输实例。
    private var available: [MockWebSocketTransport]
    /// 按 make 调用顺序保留的已分配实例。
    private var used: [MockWebSocketTransport] = []
    /// 保存待依次分配的传输实例，初始分配次数为 0。
    public init(_ transports: [MockWebSocketTransport]) { available = transports }
    /// 取出下一个预设实例；耗尽后创建默认模拟传输，并计入分配次数。
    public func make() -> any WebSocketTransport {
        lock.lock(); defer { lock.unlock() }
        let transport = available.isEmpty ? MockWebSocketTransport() : available.removeFirst()
        used.append(transport)
        return transport
    }
    /// 截至读取时 make 已分配的实例总数。
    public var count: Int { lock.lock(); defer { lock.unlock() }; return used.count }
}

/// 由测试显式推进的时钟；取消会移除对应等待者。
public actor TestNetworkClock: NetworkClock {
    private struct Waiter {
        /// 相对于测试时钟原点的到期秒数。
        let deadline: TimeInterval
        /// 到期或取消时恢复一次的等待上下文。
        let continuation: CheckedContinuation<Void, any Error>
    }
    /// 测试时钟当前秒数，初始为 0，仅由 advance 推进。
    private var now: TimeInterval = 0
    /// 按等待身份保存的截止时间及 continuation。
    private var waiters: [UUID: Waiter] = [:]
    /// 创建时间为零且没有等待者的测试时钟。
    public init() {}
    /// 当前尚未到期或取消的等待者数量。
    public var pendingCount: Int { waiters.count }
    /// 登记相对当前时钟的等待；非正秒数直接返回，取消会恢复对应等待者。
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
    /// 将时钟推进指定秒数并恢复所有已到期等待者；负数按零处理。
    public func advance(by seconds: TimeInterval) {
        now += max(0, seconds)
        for (id, waiter) in waiters where waiter.deadline <= now {
            waiters.removeValue(forKey: id); waiter.continuation.resume()
        }
    }
    /// 移除指定等待者并抛出 CancellationError；已完成时不再恢复。
    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
}
