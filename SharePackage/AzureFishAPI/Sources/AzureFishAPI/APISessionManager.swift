import Foundation
import AzureFishNetwork

/// 持久化单元；pendingRefreshOperationID 与旧凭据必须在一个原子写入中保存。
public struct APISessionRecord: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentials: SessionCredentials
    public let pendingRefreshOperationID: UUID?
    public init(credentials: SessionCredentials, pendingRefreshOperationID: UUID? = nil) {
        self.credentials = credentials; self.pendingRefreshOperationID = pendingRefreshOperationID
    }
    public var description: String { "APISessionRecord(<redacted>)" }
    public var debugDescription: String { description }
}

/// 环境隔离的异步安全存储；save 必须原子替换完整记录，失败时保留原记录。
///
/// 生产调用方必须提供 Keychain 或等效实现；管理器不提供内存回退。
public protocol APISessionStore: Sendable {
    func load(environmentID: String) async throws -> APISessionRecord?
    func save(_ record: APISessionRecord, environmentID: String) async throws
    func clear(environmentID: String) async throws
}

public enum APISessionError: Error, Sendable, Equatable {
    case noSession, sessionChanged, storageFailure
}

/// 不携带令牌的会话变化通知；generation 在恢复、替换和清理时变化。
public struct APISessionState: Sendable, Equatable {
    public let generation: UUID
    public let userID: UUID?
    public let sessionID: UUID?
    public let refreshGeneration: Int64?
}

/// 统一账号凭据持久化、HTTP 认证重试与 WebSocket 刷新协作。
///
/// 一个存储环境由一个管理器拥有；跨进程互斥由存储实现负责。
public actor APISessionManager {
    public nonisolated let api: AccountAPI
    public nonisolated var environment: APIEnvironment { api.environment }
    private let store: any APISessionStore
    private let persistence = SessionPersistenceLane()
    private var epoch = UUID()
    private var record: APISessionRecord?
    private var endingSession = false
    private var refreshTask: Task<SessionCredentials, any Error>?
    private var refreshID: UUID?
    private var requests: [UUID: @Sendable () -> Void] = [:]
    private var subscribers: [UUID: AsyncStream<APISessionState>.Continuation] = [:]

    public init(api: AccountAPI, store: any APISessionStore) { self.api = api; self.store = store }

    public var state: APISessionState {
        let visible = endingSession ? nil : record?.credentials
        return APISessionState(generation: epoch, userID: visible?.userID,
                               sessionID: visible?.sessionID, refreshGeneration: visible?.refreshGeneration)
    }

    public func changes() -> AsyncStream<APISessionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<APISessionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation; continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// 恢复完整记录；遇到未完成刷新时复用原操作身份，网络失败保留恢复记录。
    public func restore() async throws {
        let generation = invalidate()
        let store = store, environment = environment.identifier
        let loaded = try await persistence.submit { try await store.load(environmentID: environment) }.value
        try check(generation)
        if let loaded, loaded.credentials.environmentID != environment { throw APIClientError.credentialsMismatch }
        record = loaded; publish()
        if loaded?.pendingRefreshOperationID != nil { _ = try await refresh() }
    }

    /// 先停止旧会话，再持久化新凭据；存储失败时不会发布新会话。
    public func install(_ credentials: SessionCredentials) async throws {
        guard credentials.environmentID == environment.identifier else { throw APIClientError.credentialsMismatch }
        let generation = invalidate(), value = APISessionRecord(credentials: credentials)
        try await save(value)
        try check(generation)
        record = value; publish()
    }

    /// 返回当前凭据；有 pending refresh 时先完成其恢复，避免使用已被消费的旧代次。
    public func credentials() async throws -> SessionCredentials {
        guard !endingSession, let record else { throw APISessionError.noSession }
        if record.pendingRefreshOperationID != nil || refreshTask != nil { return try await refresh() }
        return record.credentials
    }

    /// 与 HTTP 及实时连接共享一次刷新。取消单个调用不会取消该刷新。
    public func refresh() async throws -> SessionCredentials {
        guard !endingSession else { throw APISessionError.noSession }
        if let refreshTask { return try await waitForSharedNetworkTask(refreshTask) }
        guard let record else { throw APISessionError.noSession }
        let generation = epoch, id = UUID()
        let operationID = record.pendingRefreshOperationID ?? UUID()
        refreshID = id
        let task = Task { [weak self] () throws -> SessionCredentials in
            guard let self else { throw APISessionError.noSession }
            do {
                let credentials = try await self.performRefresh(record.credentials, operationID: operationID, generation: generation)
                await self.finishRefresh(id)
                return credentials
            } catch { await self.finishRefresh(id); throw error }
        }
        refreshTask = task
        return try await waitForSharedNetworkTask(task)
    }

    /// 执行原先准备的受保护操作，最多进行一次明确认证失败后的重试。
    public func execute<Value: Sendable>(_ operation: AccountOperation<Value>) async throws -> Value {
        let api = api
        guard operation.authorization != nil else { throw APIClientError.missingCredentials }
        return try await authorized { credentials in try await api.execute(operation, using: credentials) }
    }

    public func profile() async throws -> UserProfile {
        let api = api
        return try await authorized { try await api.profile(using: $0) }
    }

    /// 对策略关闭进行 HTTP 确认。仅明确 401＋UNAUTHENTICATED 才触发共享刷新。
    /// - Returns: 凭据确实变化时为 true；认证有效时为 false，应停止策略关闭重连。
    public func confirmRealtimeAuthentication(using rejected: SessionCredentials) async throws -> Bool {
        let generation = epoch
        let current = try await credentials()
        try check(generation)
        guard SessionIdentity(rejected).accepts(current) else { throw APISessionError.sessionChanged }
        if current != rejected { return true }
        do { _ = try await tracked { [api] in try await api.profile(using: current) }; try check(generation); return false }
        catch {
            try check(generation)
            guard isUnauthenticated(error) else { throw error }
            if let latest = record?.credentials, latest != current { return true }
            _ = try await refresh(); try check(generation)
            return true
        }
    }

    /// 立即停止旧任务与实时订阅，再撤销服务端会话。失败保留存储，调用方可重试相同 operationID。
    public func logout(operationID: UUID = UUID()) async throws {
        let sourceGeneration = epoch
        let old = endingSession ? record?.credentials : try await credentials()
        try check(sourceGeneration)
        guard let old else { throw APISessionError.noSession }
        let operation = try api.prepareLogout(operationID: operationID, using: old)
        let pending = record?.pendingRefreshOperationID
        let generation = invalidate()
        endingSession = true; record = APISessionRecord(credentials: old, pendingRefreshOperationID: pending)
        var current = old
        if let pending { current = try await performRefresh(old, operationID: pending, generation: generation) }
        do {
            let sending = current
            _ = try await tracked { [api] in try await api.execute(operation, using: sending) }
        } catch {
            try check(generation)
            guard isUnauthenticated(error) else { throw error }
            let renewed = try await performRefresh(current, operationID: UUID(), generation: generation)
            _ = try await tracked { [api] in try await api.execute(operation, using: renewed) }
        }
        try check(generation)
        try await clearStored()
        try check(generation)
        record = nil; endingSession = false; publish()
    }

    /// 显式清除本机凭据；不承诺服务端撤销成功，也不清理应用业务数据库。
    public func clearLocalSession() async throws {
        let generation = invalidate()
        try await clearStored()
        try check(generation)
    }

    private func authorized<Value: Sendable>(_ work: @escaping @Sendable (SessionCredentials) async throws -> Value) async throws -> Value {
        let generation = epoch, initial = try await credentials()
        try check(generation)
        do {
            let value = try await tracked { try await work(initial) }
            try check(generation); return value
        } catch {
            try check(generation)
            guard isUnauthenticated(error) else { throw error }
            let latest = try await credentials()
            try check(generation)
            let retry = latest != initial ? latest : try await refresh()
            try check(generation)
            let value = try await tracked { try await work(retry) }
            try check(generation); return value
        }
    }

    private func performRefresh(_ old: SessionCredentials, operationID: UUID, generation: UUID) async throws -> SessionCredentials {
        try check(generation)
        let pending = APISessionRecord(credentials: old, pendingRefreshOperationID: operationID)
        try await save(pending)
        try check(generation); try Task.checkCancellation()
        record = pending
        let operation = try api.prepareRefresh(operationID: operationID, using: old)
        let session = try await api.execute(operation)
        try check(generation); try Task.checkCancellation()
        let next = APISessionRecord(credentials: session.credentials)
        try await save(next)
        try check(generation); try Task.checkCancellation()
        record = next; publish()
        return session.credentials
    }
    private func tracked<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID(), task = Task { try await work() }
        requests[id] = { task.cancel() }
        defer { requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func save(_ value: APISessionRecord) async throws {
        let store = store, environment = environment.identifier
        try await persistence.submit { try await store.save(value, environmentID: environment) }.value
    }
    private func clearStored() async throws {
        let store = store, environment = environment.identifier
        try await persistence.submit { try await store.clear(environmentID: environment) }.value
    }
    @discardableResult
    private func invalidate() -> UUID {
        epoch = UUID(); record = nil; endingSession = false
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        for cancel in requests.values { cancel() }; requests.removeAll()
        publish()
        return epoch
    }
    private func check(_ generation: UUID) throws {
        guard epoch == generation else { throw APISessionError.sessionChanged }
        try Task.checkCancellation()
    }
    private func finishRefresh(_ id: UUID) { if refreshID == id { refreshID = nil; refreshTask = nil } }
    private func isUnauthenticated(_ error: any Error) -> Bool {
        if case APIClientError.service(let failure) = error { return failure.isUnauthenticated }
        return false
    }
    private func publish() { for continuation in subscribers.values { continuation.yield(state) } }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    deinit {
        refreshTask?.cancel()
        for cancel in requests.values { cancel() }
        for continuation in subscribers.values { continuation.finish() }
    }
}

/// 写入排队在调用线程同步完成，避免 actor 重入导致旧保存越过新会话清理。
private final class SessionPersistenceLane: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    func submit<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, any Error> {
        lock.lock(); defer { lock.unlock() }
        let previous = tail
        let task = Task {
            await previous?.value
            do { return try await operation() } catch { throw APISessionError.storageFailure }
        }
        tail = Task { _ = await task.result }
        return task
    }
}
