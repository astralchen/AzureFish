import Foundation

/// WebSocket 应用消息；描述不包含正文。
public enum WebSocketMessage: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case text(String)
    case binary(Data)
    /// 正文的字节数；文本按 UTF-8 计算，不含 WebSocket 帧开销。
    public var byteCount: Int {
        switch self { case .text(let text): text.utf8.count; case .binary(let data): data.count }
    }
    /// 仅显示正文长度的脱敏描述。
    public var description: String { "WebSocketMessage(bytes: \(byteCount))" }
    /// 与 description 相同的脱敏调试描述。
    public var debugDescription: String { description }
}

/// 不包含原始关闭原因、地址或系统错误正文的连接失败。
public enum WebSocketError: Error, Sendable, Equatable {
    case invalidConfiguration, invalidHandshake, insecureURL, notConnected, shutdown
    case handshakeTimeout, sendTimeout, pongTimeout
    case handshakeRejected(status: Int), closed(code: Int), transport(code: Int), transportFailed
    case messageTooLarge, queueFull, receiveOverflow, deliveryUncertain, reconnectExhausted
    case duplicateRequest, requestTimeout, staleGeneration

    /// 当前错误是否属于连接层允许尝试自动重连的暂时性失败。
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
    /// 保留已知 WebSocket 错误或 URLError 代码，其余错误归为 transportFailed。
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
    /// 本次握手的完整地址；原生传输在连接时按 WS／WSS 安全策略校验。
    public let url: URL
    /// 本次握手的原始请求头，默认空字典；可能包含凭据，不得记录原文。
    public let headers: [String: String]
    /// 保存握手地址和请求头；不发起连接，也不在此处校验输入。
    public init(url: URL, headers: [String: String] = [:]) { self.url = url; self.headers = headers }
    /// 隐藏地址和请求头的固定描述。
    public var description: String { "WebSocketHandshake(<redacted>)" }
    /// 与 description 相同的脱敏调试描述。
    public var debugDescription: String { description }
}

/// 可替换的单次连接传输；close 必须终止待处理的 connect、receive 和 ping。
///
/// 调用方须维持单个 receive 循环以处理应用帧和控制帧；WebSocketConnection 自动负责该循环。
public protocol WebSocketTransport: Sendable {
    /// 建立一次连接并等待握手结果；接收消息应遵守 maximumMessageBytes 字节上限。
    ///
    /// - Throws: 握手失败或取消；实现须允许 close 终止未完成的握手。
    func connect(_ handshake: WebSocketHandshake, maximumMessageBytes: Int) async throws
    /// 提交一条应用消息；成功仅代表传输提交完成，不代表业务确认。
    func send(_ message: WebSocketMessage) async throws
    /// 等待下一条应用消息；调用方须维持单个接收循环，close 须终止等待。
    func receive() async throws -> WebSocketMessage
    /// 发送 ping 并等待对应 pong；close 须终止未完成的等待。
    func ping() async throws
    /// 关闭连接并终止未完成的握手、接收和心跳操作。
    func close() async
}

/// 可注入的等待机制；实现须响应任务取消。
public protocol NetworkClock: Sendable {
    /// 挂起指定秒数；实现须响应调用任务的取消并抛出取消错误。
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemNetworkClock: NetworkClock {
    /// 创建使用 Task.sleep 的系统等待机制。
    public init() {}
    /// 将有限的等待秒数限制在 0～86400 后挂起；任务取消时抛出 CancellationError。
    ///
    /// - Parameter seconds: 有限秒数；直接调用时须由调用方排除 NaN 及无穷值。
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
    /// 创建默认配置；连接初始化时校验，已启用的超时及间隔须为有限值并满足 (0, 86400] 秒。
    public init() {}
    /// 校验超时、退避、重连次数及队列容量；无效时抛出 invalidConfiguration。
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
