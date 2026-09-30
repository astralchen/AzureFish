import Foundation
import AzureFishNetwork

/// 持久化单元；pendingRefreshOperationID 与旧凭据必须在一个原子写入中保存。
public struct APISessionRecord: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 当前持久化单元中的完整会话凭据快照。
    public let credentials: SessionCredentials
    /// 尚未确认完成的刷新操作身份；nil 表示没有待恢复刷新。
    public let pendingRefreshOperationID: UUID?
    /// 组合凭据与未决刷新身份；默认无未决刷新，不执行持久化。
    public init(credentials: SessionCredentials, pendingRefreshOperationID: UUID? = nil) {
        self.credentials = credentials; self.pendingRefreshOperationID = pendingRefreshOperationID
    }
    /// 隐藏凭据及未决操作身份的固定说明。
    public var description: String { "APISessionRecord(<redacted>)" }
    /// 与 description 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 环境隔离的异步安全存储；save 必须原子替换完整记录，失败时保留原记录。
///
/// 生产调用方必须提供 Keychain 或等效实现；管理器不提供内存回退。
public protocol APISessionStore: Sendable {
    /// 读取指定环境的完整会话记录；不存在时返回 nil，读取失败须抛错。
    func load(environmentID: String) async throws -> APISessionRecord?
    /// 原子替换指定环境的完整记录；失败时必须保留原记录，不能部分更新令牌或刷新身份。
    func save(_ record: APISessionRecord, environmentID: String) async throws
    /// 删除指定环境的会话记录；不能删除其他环境的凭据或业务存储密钥。
    func clear(environmentID: String) async throws
}

public enum APISessionError: Error, Sendable, Equatable {
    case noSession, sessionChanged, storageFailure, verificationRequired
}

/// 不携带令牌的会话变化通知；generation 在恢复、替换和清理时变化。
public struct APISessionState: Sendable, Equatable {
    /// 当前管理器会话代次；用于拒绝恢复、替换或清理前发起的迟到结果。
    public let generation: UUID
    /// 当前可见会话的用户身份；无会话或正在退出时为 nil。
    public let userID: UUID?
    /// 当前可见会话身份；无会话或正在退出时为 nil。
    public let sessionID: UUID?
    /// 可见凭据的刷新代次；没有可见会话时为 nil。
    public let refreshGeneration: Int64?
    /// 服务器已明确拒绝会话；调用方应结束该账号的界面和本地会话访问。
    public var requiresReauthentication: Bool = false
}

/// 统一账号凭据持久化、HTTP 认证重试与 WebSocket 刷新协作。
///
/// 一个存储环境由一个管理器拥有；跨进程互斥由存储实现负责。
public actor APISessionManager {
    /// 此管理器使用的账号 API，决定会话所属环境。
    public nonisolated let api: AccountAPI
    /// 账号 API 对应的固定服务环境。
    public nonisolated var environment: APIEnvironment { api.environment }
    /// 调用方注入的环境隔离凭据存储，管理器不提供内存回退。
    private let store: any APISessionStore
    /// 序列化凭据加载、保存和清理的执行通道。
    private let persistence = SessionPersistenceLane()
    /// 当前会话工作代次；失效后旧异步结果不能安装。
    private var epoch = UUID()
    /// 当前内存凭据及未决刷新记录；nil 表示没有已安装记录。
    private var record: APISessionRecord?
    /// 是否正在退出；为 true 时不向普通调用方暴露旧会话。
    private var endingSession = false
    /// 是否允许普通受保护调用取用凭据，初始为 true；显式认证校验另行处理。
    private var networkAccessAllowed = true
    /// 是否收到明确的会话拒绝结果；为 true 时普通网络访问被禁止。
    private var requiresReauthentication = false
    /// 所有刷新调用共享的任务；单个等待者取消不会取消此任务。
    private var refreshTask: Task<SessionCredentials, any Error>?
    /// 当前刷新任务身份，防止旧任务完成时清除新的刷新任务。
    private var refreshID: UUID?
    /// 尚未完成的受保护任务取消操作，按请求身份索引。
    private var requests: [UUID: @Sendable () -> Void] = [:]
    /// 只保留最新状态的会话订阅，结束时移除。
    private var subscribers: [UUID: AsyncStream<APISessionState>.Continuation] = [:]

    /// 保存账号 API 和安全存储；不自动恢复、校验或安装会话。
    public init(api: AccountAPI, store: any APISessionStore) { self.api = api; self.store = store }

    /// 不含令牌的当前会话状态；正在退出时隐藏用户、会话及刷新代次。
    public var state: APISessionState {
        let visible = endingSession ? nil : record?.credentials
        return APISessionState(generation: epoch, userID: visible?.userID,
                               sessionID: visible?.sessionID, refreshGeneration: visible?.refreshGeneration, requiresReauthentication: requiresReauthentication)
    }

    /// 创建独立会话状态流并立即提交当前状态；缓冲只保留最新一项。
    public func changes() -> AsyncStream<APISessionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<APISessionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation; continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// 恢复完整记录；遇到未完成刷新时复用原操作身份，网络失败保留恢复记录。
    public func restore() async throws {
        try await restoreLocal()
        if record?.pendingRefreshOperationID != nil { _ = try await refresh() }
    }

    /// 只恢复本地身份和未决操作，不等待网络；调用方须在验证期间关闭业务网络访问。
    public func restoreLocal() async throws {
        let generation = invalidate()
        let store = store, environment = environment.identifier
        let loaded = try await persistence.submit { try await store.load(environmentID: environment) }.value
        try check(generation)
        if let loaded, loaded.credentials.environmentID != environment { throw APIClientError.credentialsMismatch }
        record = loaded; publish()
    }

    /// 控制普通 HTTP 和实时连接能否取用凭据；本地身份与显式认证校验仍可用。
    public func setNetworkAccessAllowed(_ allowed: Bool) {
        networkAccessAllowed = allowed
        if !allowed { requests.values.forEach { $0() } }
    }

    /// 校验已恢复会话；本地到期判断仅触发刷新，是否失效由服务器确认。
    public func validateSession(now: Date = Date()) async throws -> UserProfile {
        guard !endingSession, let record else { throw APISessionError.noSession }
        let generation = epoch
        var credentials = record.credentials
        if record.pendingRefreshOperationID != nil || credentials.accessExpiresAt <= now || credentials.refreshExpiresAt <= now {
            credentials = try await refresh()
        }
        try check(generation)
        do {
            let current = credentials
            let profile = try await tracked { [api] in try await api.profile(using: current) }
            try check(generation)
            return profile
        } catch {
            try check(generation)
            guard isUnauthenticated(error) else { throw error }
            let renewed = try await refresh()
            let profile = try await tracked { [api] in try await api.profile(using: renewed) }
            try check(generation)
            return profile
        }
    }

    /// 先停止旧会话，再持久化新凭据；存储失败时不会发布新会话。
    public func install(_ credentials: SessionCredentials) async throws {
        guard credentials.environmentID == environment.identifier else { throw APIClientError.credentialsMismatch }
        let generation = invalidate(), value = APISessionRecord(credentials: credentials)
        try await save(value)
        try check(generation)
        record = value; networkAccessAllowed = true; publish()
    }

    /// 返回当前身份供离线草稿绑定；不保证访问令牌有效，也不发起刷新。
    public func localIdentity() throws -> SessionCredentials {
        guard !endingSession, let record else { throw APISessionError.noSession }
        return record.credentials
    }
    /// 返回当前凭据；有 pending refresh 时先完成其恢复，避免使用已被消费的旧代次。
    public func credentials() async throws -> SessionCredentials {
        guard !endingSession, let record else { throw APISessionError.noSession }
        guard networkAccessAllowed, !requiresReauthentication else { throw APISessionError.verificationRequired }
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
            } catch {
                await self.noteAuthenticationFailure(error, generation: generation)
                await self.finishRefresh(id)
                throw error
            }
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

    /// 使用当前会话读取用户资料；明确认证失败时遵循共享刷新及一次重试策略。
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
        let old = record?.credentials
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

    /// 在同一会话代次执行受保护传输，仅对明确认证失败进行一次重试。
    public func authorized<Value: Sendable>(_ work: @escaping @Sendable (SessionCredentials) async throws -> Value) async throws -> Value {
        let generation = epoch, initial = try await credentials()
        try check(generation)
        do {
            let value = try await tracked { try await work(initial) }
            try check(generation)
            guard networkAccessAllowed else { throw APISessionError.verificationRequired }
            return value
        } catch {
            try check(generation)
            guard networkAccessAllowed else { throw APISessionError.verificationRequired }
            guard isUnauthenticated(error) else { throw error }
            let latest = try await credentials()
            try check(generation)
            let retry = latest != initial ? latest : try await refresh()
            try check(generation)
            do {
                let value = try await tracked { try await work(retry) }
                try check(generation)
                guard networkAccessAllowed else { throw APISessionError.verificationRequired }
                return value
            } catch { noteAuthenticationFailure(error, generation: generation); throw error }
        }
    }

    /// 先持久化旧凭据与刷新身份，再请求刷新并保存新凭据；每个阶段校验会话代次。
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
    /// 登记异步任务以响应会话失效及调用方取消，并在结束时移除登记。
    private func tracked<Value: Sendable>(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = UUID(), task = Task { try await work() }
        requests[id] = { task.cancel() }
        defer { requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    /// 通过串行持久化通道保存当前环境记录；存储错误映射为 storageFailure。
    private func save(_ value: APISessionRecord) async throws {
        let store = store, environment = environment.identifier
        try await persistence.submit { try await store.save(value, environmentID: environment) }.value
    }
    /// 通过串行持久化通道清除当前环境凭据；存储错误映射为 storageFailure。
    private func clearStored() async throws {
        let store = store, environment = environment.identifier
        try await persistence.submit { try await store.clear(environmentID: environment) }.value
    }
    /// 创建新会话代次，清空内存记录并取消刷新及受保护任务，随后发布状态。
    @discardableResult
    private func invalidate() -> UUID {
        epoch = UUID(); record = nil; endingSession = false; requiresReauthentication = false
        refreshTask?.cancel(); refreshTask = nil; refreshID = nil
        for cancel in requests.values { cancel() }; requests.removeAll()
        publish()
        return epoch
    }
    /// 确认异步结果仍属于当前代次并检查调用任务是否取消。
    private func check(_ generation: UUID) throws {
        guard epoch == generation else { throw APISessionError.sessionChanged }
        try Task.checkCancellation()
    }
    /// 仅在任务身份仍匹配时清除当前刷新任务。
    private func finishRefresh(_ id: UUID) { if refreshID == id { refreshID = nil; refreshTask = nil } }
    /// 仅接纳当前代次的明确认证拒绝，关闭普通网络访问并发布重新认证状态。
    private func noteAuthenticationFailure(_ error: any Error, generation: UUID) {
        guard epoch == generation, !endingSession,
              case APIClientError.service(let failure) = error,
              [.unauthenticated, .refreshReplay, .refreshSuperseded, .authAttemptExpired].contains(failure.code) else { return }
        requiresReauthentication = true
        networkAccessAllowed = false
        publish()
    }
    /// 判断错误是否为服务端明确的 401 与 UNAUTHENTICATED 组合。
    private func isUnauthenticated(_ error: any Error) -> Bool {
        if case APIClientError.service(let failure) = error { return failure.isUnauthenticated }
        return false
    }
    /// 向所有状态订阅提交当前会话快照，慢订阅者只保留最新状态。
    private func publish() { for continuation in subscribers.values { continuation.yield(state) } }
    /// 移除已结束的会话状态订阅。
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    /// 请求取消刷新及受保护任务，并结束全部状态订阅。
    deinit {
        refreshTask?.cancel()
        for cancel in requests.values { cancel() }
        for continuation in subscribers.values { continuation.finish() }
    }
}

/// 写入排队在调用线程同步完成，避免 actor 重入导致旧保存越过新会话清理。
private final class SessionPersistenceLane: @unchecked Sendable {
    /// 保护任务链尾部替换的互斥锁，使入队顺序在调用时确定。
    private let lock = NSLock()
    /// 最后一次已登记操作的完成观察任务；失败也不会阻断后续操作。
    private var tail: Task<Void, Never>?
    /// 同步登记串行操作并返回其任务；前项结束后执行，所有操作错误映射为 storageFailure。
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
