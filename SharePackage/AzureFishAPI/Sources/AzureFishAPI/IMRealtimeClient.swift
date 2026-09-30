import Foundation
import AzureFishNetwork
import AzureFishProtocol
import SwiftProtobuf

/// 服务端同步提示的业务值；cursor 只能触发补拉，不能作为已提交 checkpoint。
public struct IMRealtimeHint: Sendable, Equatable {
    /// 服务端同步代次；变化时应重新建立同步基线。
    public let epoch: UUID
    /// 服务端提示的最新游标，只能用于触发补拉，不能直接写为已提交检查点。
    public let cursor: String
    /// 提示中的当前用户资料版本，默认 0 表示没有可用版本提示。
    public var ownProfileVersion: Int64 = 0
}

/// 可合并的 HTTP 补拉通知；每个通知携带会话作用域供调用方隔离迟到结果。
public struct IMRealtimeSignal: Sendable, Equatable {
    public enum Reason: Sendable { case connected, hintChanged, receiveGap }
    /// 触发 HTTP 补拉的原因，包括连接建立、提示变化或接收缺口。
    public let reason: Reason
    /// 最近一次有效实时提示；尚未收到提示时为 nil。
    public let hint: IMRealtimeHint?
    /// 产生此信号时的会话作用域，供接收方排除旧会话结果。
    public let session: APISessionState
}

public enum IMRealtimeError: Error, Sendable, Equatable {
    case policyClosed, invalidHint, authenticationConfirmationFailed
    case connection(WebSocketError)
}

public enum IMRealtimeState: Sendable, Equatable {
    case stopped, connecting, connected, reconnecting, failed(IMRealtimeError)
}

/// 只消费 IM 实时提示的适配器；构造不会连接，应用必须显式 start。
///
/// 不发送消息、不持久化增量，也不管理客户端 checkpoint。
public actor IMRealtimeClient {
    /// 提供共享凭据、认证确认和会话状态的管理器。
    private let manager: APISessionManager
    /// 为每次连接尝试创建单次传输实例的工厂。
    private let factory: WebSocketConnection.TransportFactory
    /// 用于 WebSocket 超时、退避和心跳的等待机制。
    private let clock: any NetworkClock
    /// 是否已请求启动实时观察，初始为 false。
    private var active = false
    /// 本次会话观察身份，防止旧观察循环在重新启动后产生作用。
    private var observationID = UUID()
    /// 当前实时连接代次，关闭或重建时更新。
    private var generation = UUID()
    /// 最近接纳的会话状态；未启动或停止后为 nil。
    private var observedSession: APISessionState?
    /// 当前握手实际使用的凭据，供策略关闭后的 HTTP 认证确认使用。
    private var handshakeCredentials: SessionCredentials?
    /// 当前实时提示连接；重建或停止时关闭并清空。
    private var connection: WebSocketConnection?
    /// 消费管理器会话变化的任务。
    private var sessionTask: Task<Void, Never>?
    /// 消费当前连接实时提示消息的任务。
    private var messageTask: Task<Void, Never>?
    /// 消费当前连接状态变化的任务。
    private var stateTask: Task<Void, Never>?
    /// 等待当前连接握手结果的任务。
    private var connectTask: Task<Void, Never>?
    /// 策略关闭后的单一 HTTP 认证确认任务。
    private var confirmationTask: Task<Void, Never>?
    /// 对外发布的实时状态，初始为 stopped。
    private var state: IMRealtimeState = .stopped
    /// 当前连接最近一次有效提示，用于合并重复提示。
    private var lastHint: IMRealtimeHint?
    /// 当前连接最近一次补拉信号，供新订阅者立即获取。
    private var lastSignal: IMRealtimeSignal?
    /// 独立补拉信号订阅，每个订阅只保留最新信号。
    private var signals: [UUID: AsyncStream<IMRealtimeSignal>.Continuation] = [:]
    /// 独立实时状态订阅，每个订阅只保留最新状态。
    private var states: [UUID: AsyncStream<IMRealtimeState>.Continuation] = [:]

    /// 保存会话管理器、时钟及传输工厂；默认工厂沿用会话环境的安全策略，不立即连接。
    public init(sessionManager: APISessionManager, clock: any NetworkClock = SystemNetworkClock(),
                transportFactory: WebSocketConnection.TransportFactory? = nil) {
        manager = sessionManager; self.clock = clock
        let security = sessionManager.environment.security
        factory = transportFactory ?? { URLSessionWebSocketTransport(security: security) }
    }

    /// 读取时的实时连接状态快照。
    public var currentState: IMRealtimeState { state }

    /// 开始观察会话并连接；实际连接结果通过 stateChanges 发布。
    public func start() async {
        guard !active else { return }
        active = true
        let observation = UUID(); observationID = observation
        let stream = await manager.changes()
        guard active, observationID == observation else { return }
        sessionTask = Task { [weak self] in
            for await session in stream {
                guard !Task.isCancelled else { break }
                await self?.sessionChanged(session, observation: observation)
            }
        }
    }

    /// 停止连接与旧会话观察；之后可再次 start。
    public func stop() async {
        active = false; observationID = UUID(); sessionTask?.cancel(); sessionTask = nil; observedSession = nil
        let id = await closeConnection()
        if generation == id, !active { setState(.stopped) }
    }

    /// 创建状态流并立即提交当前状态；只缓冲最新状态，stop 不结束此订阅。
    public func stateChanges() -> AsyncStream<IMRealtimeState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IMRealtimeState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        states[id] = continuation; continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeState(id) } }
        return stream
    }

    /// 每个订阅只保留最新补拉信号；真实消息缺口必须通过 HTTP 恢复。
    public func syncSignals() -> AsyncStream<IMRealtimeSignal> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IMRealtimeSignal>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals[id] = continuation
        if let lastSignal { continuation.yield(lastSignal) }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSignal(id) } }
        return stream
    }

    /// 接纳当前观察周期的会话变化并重建连接；重复或过期状态被忽略。
    private func sessionChanged(_ session: APISessionState, observation: UUID) async {
        guard active, observationID == observation, observedSession != session else { return }
        observedSession = session
        await rebuild()
    }

    /// 结束旧连接，按当前会话建立只消费同步提示的新连接及订阅。
    private func rebuild() async {
        let id = await closeConnection()
        guard generation == id, active else { return }
        guard observedSession?.sessionID != nil else { setState(.stopped); return }
        let manager = manager
        var configuration = WebSocketConfiguration()
        configuration.maximumMessageBytes = 4 * 1024
        configuration.pingInterval = 25; configuration.pongTimeout = 10
        do {
            let socket = try WebSocketConnection(configuration: configuration, clock: clock, transportFactory: factory) { [weak self] in
                let credentials = try await manager.credentials()
                guard let self, await self.accept(credentials, generation: id) else { throw APISessionError.sessionChanged }
                var components = URLComponents(url: manager.environment.url(path: "v1/im/live"), resolvingAgainstBaseURL: false)!
                components.scheme = components.scheme == "https" ? "wss" : "ws"
                return WebSocketHandshake(url: components.url!, headers: ["Authorization": "Bearer \(credentials.accessToken.rawValue)"])
            }
            connection = socket
            let messages = await socket.messages(), changes = await socket.stateChanges()
            guard generation == id, active else { await socket.shutdown(); return }
            messageTask = Task { [weak self] in
                do {
                    for try await message in messages {
                        guard !Task.isCancelled else { return }
                        await self?.received(message, generation: id)
                    }
                } catch {
                    if error as? WebSocketError == .receiveOverflow { await self?.receiveGap(generation: id) }
                }
            }
            stateTask = Task { [weak self] in
                for await state in changes {
                    guard !Task.isCancelled else { return }
                    await self?.connectionChanged(state, generation: id)
                }
            }
            connectTask = Task { try? await socket.connect() }
        } catch { setState(.failed(.connection(.invalidConfiguration))) }
    }

    /// 确认握手凭据仍匹配当前连接代次、用户和会话，匹配时保存用于认证确认。
    private func accept(_ credentials: SessionCredentials, generation: UUID) -> Bool {
        guard active, self.generation == generation, observedSession?.sessionID == credentials.sessionID,
              observedSession?.userID == credentials.userID else { return false }
        handshakeCredentials = credentials
        return true
    }

    /// 解析不超过 4 KiB 的二进制同步提示并合并重复值；无效提示触发补拉信号并关闭连接。
    private func received(_ message: WebSocketMessage, generation: UUID) async {
        guard active, self.generation == generation else { return }
        guard case .binary(let bytes) = message, bytes.count <= 4096,
              let proto = try? AzureFishProtocol.IMSyncHint(serializedBytes: bytes),
              let epoch = UUID(uuidString: proto.epoch), !proto.latestCursor.isEmpty else {
            emit(.receiveGap)
            let closed = await closeConnection()
            if self.generation == closed { setState(.failed(.invalidHint)) }; return
        }
        let hint = IMRealtimeHint(epoch: epoch, cursor: proto.latestCursor, ownProfileVersion: proto.ownProfileVersion)
        if hint != lastHint { lastHint = hint; emit(.hintChanged) }
    }

    /// 将底层状态映射为业务状态；策略关闭或握手 401 触发一次 HTTP 认证确认。
    private func connectionChanged(_ socketState: WebSocketState, generation: UUID) async {
        guard active, self.generation == generation else { return }
        switch socketState {
        case .connected: setState(.connected); emit(.connected)
        case .connecting: setState(.connecting)
        case .reconnecting: setState(.reconnecting)
        case .failed(let error):
            if error == .messageTooLarge || error == .receiveOverflow || error == .closed(code: 1009) { emit(.receiveGap) }
            if error == .closed(code: 1008) || error == .handshakeRejected(status: 401) {
                guard confirmationTask == nil, let credentials = handshakeCredentials else {
                    setState(.failed(.authenticationConfirmationFailed)); return
                }
                confirmationTask = Task { [weak self, manager] in
                    do {
                        let changed = try await manager.confirmRealtimeAuthentication(using: credentials)
                        await self?.confirmed(changed: changed, generation: generation)
                    } catch { await self?.confirmationFailed(generation: generation) }
                }
            } else { setState(.failed(.connection(error))) }
        case .disconnected, .shutdown: break
        }
    }

    /// 处理当前代次认证确认结果；凭据已更新时重建连接，否则停止策略关闭重连。
    private func confirmed(changed: Bool, generation: UUID) async {
        guard active, self.generation == generation else { return }
        confirmationTask = nil
        if changed {
            let current = await manager.state
            guard active, self.generation == generation else { return }
            observedSession = current
            await rebuild()
        } else {
            let closed = await closeConnection()
            if self.generation == closed { setState(.failed(.policyClosed)) }
        }
    }
    /// 将当前代次的认证确认失败发布为终止本轮连接的失败状态。
    private func confirmationFailed(generation: UUID) {
        guard active, self.generation == generation else { return }
        confirmationTask = nil; setState(.failed(.authenticationConfirmationFailed))
    }
    /// 为当前代次发布接收缺口信号，并重建连接以恢复后续提示。
    private func receiveGap(generation: UUID) async {
        guard active, self.generation == generation else { return }
        emit(.receiveGap)
        await rebuild()
    }
    /// 携带当前会话和最近提示发布补拉信号，并保存供新订阅者读取。
    private func emit(_ reason: IMRealtimeSignal.Reason) {
        guard let session = observedSession else { return }
        let signal = IMRealtimeSignal(reason: reason, hint: lastHint, session: session)
        lastSignal = signal
        for continuation in signals.values { continuation.yield(signal) }
    }
    /// 更新连接代次并清除旧任务、凭据及提示，再等待底层连接永久关闭。
    @discardableResult
    private func closeConnection() async -> UUID {
        let id = UUID(); generation = id
        connectTask?.cancel(); connectTask = nil; messageTask?.cancel(); messageTask = nil
        stateTask?.cancel(); stateTask = nil; confirmationTask?.cancel(); confirmationTask = nil
        handshakeCredentials = nil; lastHint = nil; lastSignal = nil
        let old = connection; connection = nil
        await old?.shutdown()
        return id
    }
    /// 保存并向全部状态订阅广播新的实时状态。
    private func setState(_ value: IMRealtimeState) {
        state = value; for continuation in states.values { continuation.yield(value) }
    }
    /// 移除已结束的状态订阅。
    private func removeState(_ id: UUID) { states.removeValue(forKey: id) }
    /// 移除已结束的补拉信号订阅。
    private func removeSignal(_ id: UUID) { signals.removeValue(forKey: id) }
    /// 取消全部观察任务，异步关闭连接并结束信号与状态订阅。
    deinit {
        sessionTask?.cancel(); connectTask?.cancel(); messageTask?.cancel(); stateTask?.cancel(); confirmationTask?.cancel()
        let connection = connection; Task { await connection?.shutdown() }
        for continuation in states.values { continuation.finish() }
        for continuation in signals.values { continuation.finish() }
    }
}
