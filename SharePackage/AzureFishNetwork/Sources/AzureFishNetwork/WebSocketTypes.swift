import Foundation

/// WebSocket 应用消息；描述不包含正文。
public enum WebSocketMessage: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case text(String)
    case binary(Data)
    public var byteCount: Int {
        switch self { case .text(let text): text.utf8.count; case .binary(let data): data.count }
    }
    public var description: String { "WebSocketMessage(bytes: \(byteCount))" }
    public var debugDescription: String { description }
}

/// 不包含原始关闭原因、地址或系统错误正文的连接失败。
public enum WebSocketError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidHandshake, insecureURL, notConnected, shutdown
    case handshakeTimeout, sendTimeout, pongTimeout
    case handshakeRejected(status: Int), closed(code: Int), transport(code: Int), transportFailed
    case messageTooLarge, queueFull, receiveOverflow, deliveryUncertain, reconnectExhausted
    case duplicateRequest, requestTimeout, staleGeneration

    var retryable: Bool {
        switch self {
        case .pongTimeout, .sendTimeout, .transportFailed: return true
        case .closed(let code): return code == 1001 || code == 1006 || code == 1011 || code == 1012 || code == 1013
        case .transport(let code):
            return [URLError.networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains { $0.rawValue == code }
        default: return false
        }
    }
    static func sanitize(_ error: any Error) -> WebSocketError {
        if let error = error as? WebSocketError { return error }
        if let error = error as? URLError { return .transport(code: error.code.rawValue) }
        return .transportFailed
    }
}

/// 连接状态；失败只保留脱敏分类，shutdown 为终态。
public enum WebSocketState: Sendable, Equatable {
    case disconnected, connecting, connected, reconnecting(attempt: Int), failed(WebSocketError), shutdown
}

/// 队列条目的发送结果；submitted 失败后不会自动重新入队。
public enum WebSocketEvent: Sendable, Equatable {
    case sent(UUID), sendFailed(UUID, WebSocketError)
}

/// 一次握手的地址和请求头。每次重连重新向提供器获取。
public struct WebSocketHandshake: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let headers: [String: String]
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
    public var description: String { "WebSocketHandshake(<redacted>)" }
    public var debugDescription: String { description }
}

/// 可替换的单次连接传输；close 必须终止待处理的 connect、receive 和 ping。
///
/// 调用方须维持单个 receive 循环以处理应用帧和控制帧；WebSocketConnection 自动负责该循环。
public protocol WebSocketTransport: Sendable {
    func connect(_ handshake: WebSocketHandshake, maximumMessageBytes: Int) async throws
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close() async
}

/// 可注入的等待机制；实现须响应任务取消。
public protocol NetworkClock: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemNetworkClock: NetworkClock {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(min(max(seconds, 0), 86_400) * 1_000_000_000))
    }
}

/// 有界消息、超时及重连配置。心跳默认关闭，业务适配器可显式开启。
public struct WebSocketConfiguration: Sendable {
    /// 每次握手的总等待秒数，包含异步获取握手凭据；默认 15。
    public var handshakeTimeout: TimeInterval = 15
    /// 每条已提交消息的发送等待秒数；超时报告送达不确定，默认 15。
    public var sendTimeout: TimeInterval = 15
    /// 两次 ping 之间的秒数；nil 表示关闭心跳。
    public var pingInterval: TimeInterval? = nil
    /// 每次 ping 的 pong 等待秒数，默认 10。
    public var pongTimeout: TimeInterval = 10
    /// 异常断线后的最大握手尝试次数，默认 5；0 禁用，允许 0～100。
    public var reconnectAttempts: Int = 5
    /// 指数退避的基础秒数，默认 1；实际等待乘以 0～1 的随机值。
    public var reconnectBaseDelay: TimeInterval = 1
    /// 抖动前的退避上限秒数，默认 30。
    public var reconnectMaximumDelay: TimeInterval = 30
    /// 单条消息的 UTF-8／二进制字节上限，默认 1 MiB，必须为正数。
    public var maximumMessageBytes: Int = 1_048_576
    /// 尚未提交传输的队列条数上限，默认 100，必须为正数。
    public var maximumQueuedMessages: Int = 100
    /// 尚未提交传输的队列总字节上限，默认 8 MiB，必须为正数。
    public var maximumQueuedBytes: Int = 8 * 1_048_576
    /// 订阅前缓存及各消息订阅的条数上限，默认 16，必须为正数。
    public var receiveBuffer: Int = 16
    /// 创建默认配置；连接初始化时校验，所有秒数必须有限且在 0～86400 的开闭区间内。
    public init() {}
    func validate() throws {
        guard [handshakeTimeout, sendTimeout, pongTimeout, reconnectBaseDelay, reconnectMaximumDelay].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 86_400 }),
              pingInterval.map({ $0.isFinite && $0 > 0 && $0 <= 86_400 }) ?? true,
              (0...100).contains(reconnectAttempts), maximumMessageBytes > 0, maximumQueuedMessages > 0,
              maximumQueuedBytes > 0, receiveBuffer > 0 else { throw WebSocketError.invalidConfiguration }
    }
}

extension TransportSecurityPolicy {
    /// 校验 WSS；显式 Debug 回环策略只允许字面回环 WS。
    public func validateWebSocket(_ url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw WebSocketError.insecureURL }
        switch components.scheme?.lowercased() {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: throw WebSocketError.insecureURL
        }
        guard let mapped = components.url else { throw WebSocketError.insecureURL }
        do { try validate(mapped) } catch { throw WebSocketError.insecureURL }
    }
}
