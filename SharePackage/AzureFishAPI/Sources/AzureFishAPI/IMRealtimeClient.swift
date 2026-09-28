import Foundation
import AzureFishNetwork
import AzureFishProtocol
import SwiftProtobuf

/// 服务端同步提示的业务值；cursor 只能触发补拉，不能作为已提交 checkpoint。
public struct IMRealtimeHint: Sendable, Equatable {
    public let epoch: UUID
    public let cursor: String
    public var ownProfileVersion: Int64 = 0
}

/// 可合并的 HTTP 补拉通知；每个通知携带会话作用域供调用方隔离迟到结果。
public struct IMRealtimeSignal: Sendable, Equatable {
    public enum Reason: Sendable { case connected, hintChanged, receiveGap }
    public let reason: Reason
    public let hint: IMRealtimeHint?
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
    private let manager: APISessionManager
    private let factory: WebSocketConnection.TransportFactory
    private let clock: any NetworkClock
    private var active = false
    private var observationID = UUID()
    private var generation = UUID()
    private var observedSession: APISessionState?
    private var handshakeCredentials: SessionCredentials?
    private var connection: WebSocketConnection?
    private var sessionTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var state: IMRealtimeState = .stopped
    private var lastHint: IMRealtimeHint?
    private var lastSignal: IMRealtimeSignal?
    private var signals: [UUID: AsyncStream<IMRealtimeSignal>.Continuation] = [:]
    private var states: [UUID: AsyncStream<IMRealtimeState>.Continuation] = [:]

    public init(sessionManager: APISessionManager, clock: any NetworkClock = SystemNetworkClock(),
                transportFactory: WebSocketConnection.TransportFactory? = nil) {
        manager = sessionManager; self.clock = clock
        let security = sessionManager.environment.security
        factory = transportFactory ?? { URLSessionWebSocketTransport(security: security) }
    }

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

    private func sessionChanged(_ session: APISessionState, observation: UUID) async {
        guard active, observationID == observation, observedSession != session else { return }
        observedSession = session
        await rebuild()
    }

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

    private func accept(_ credentials: SessionCredentials, generation: UUID) -> Bool {
        guard active, self.generation == generation, observedSession?.sessionID == credentials.sessionID,
              observedSession?.userID == credentials.userID else { return false }
        handshakeCredentials = credentials
        return true
    }

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
    private func confirmationFailed(generation: UUID) {
        guard active, self.generation == generation else { return }
        confirmationTask = nil; setState(.failed(.authenticationConfirmationFailed))
    }
    private func receiveGap(generation: UUID) async {
        guard active, self.generation == generation else { return }
        emit(.receiveGap)
        await rebuild()
    }
    private func emit(_ reason: IMRealtimeSignal.Reason) {
        guard let session = observedSession else { return }
        let signal = IMRealtimeSignal(reason: reason, hint: lastHint, session: session)
        lastSignal = signal
        for continuation in signals.values { continuation.yield(signal) }
    }
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
    private func setState(_ value: IMRealtimeState) {
        state = value; for continuation in states.values { continuation.yield(value) }
    }
    private func removeState(_ id: UUID) { states.removeValue(forKey: id) }
    private func removeSignal(_ id: UUID) { signals.removeValue(forKey: id) }
    deinit {
        sessionTask?.cancel(); connectTask?.cancel(); messageTask?.cancel(); stateTask?.cancel(); confirmationTask?.cancel()
        let connection = connection; Task { await connection?.shutdown() }
        for continuation in states.values { continuation.finish() }
        for continuation in signals.values { continuation.finish() }
    }
}
