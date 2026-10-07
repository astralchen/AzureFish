import AzureFishAPI
import Foundation

/// 全量快照与增量补拉的状态；本地消息变化不表示同步完成。
public enum ChatSynchronizationState: Sendable, Equatable {
    case idle, syncing, synced, failed
}

/// 标识本次通知需要重新读取的业务域；空集合只更新连接和同步状态。
public struct ChatChangeScope: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let directory = Self(rawValue: 1 << 0)
    public static let conversations = Self(rawValue: 1 << 1)
    public static let messages = Self(rawValue: 1 << 2)
    public static let transfers = Self(rawValue: 1 << 3)
    public static let all: Self = [.directory, .conversations, .messages, .transfers]
}

/// 聊天数据变化时携带的连接观察值与独立同步状态。
public struct ChatEngineUpdate: Sendable, Equatable {
    /// 最近一次同步或业务操作报告的连接观察值，不代表实时链路始终可用。
    public let online: Bool
    /// 独立的全量及增量补拉状态，本地数据改变不会自动将其标记为完成。
    public let synchronization: ChatSynchronizationState
    /// 增量同步已观察到的最大本人资料版本；0 表示尚未收到提示。
    public var ownProfileVersion: Int64 = 0
    public var scope: ChatChangeScope = .all
    /// nil 表示所有会话，非空集合表示本次改变的会话身份。
    public var conversations: Set<String>? = nil
}

/// 驱动账号隔离的 HTTP 同步和持久 outbox；WebSocket 只唤醒 HTTP 补拉。
public actor ChatEngine {
    /// 此引擎使用的账号聊天事务入口。
    public nonisolated let store: ChatStore
    /// 共享会话下的 IM 请求适配器。
    public nonisolated let api: IMAPI
    /// 只消费同步提示并唤醒 HTTP 补拉的实时客户端。
    private let realtime: IMRealtimeClient
    /// 是否已启动后台提示监听和周期补拉任务。
    private var running = false
    /// 当前共享的补拉任务；重复 synchronize 等待同一任务。
    private var syncing: Task<Void, Error>?
    /// 监听实时补拉提示的任务。
    private var signals: Task<Void, Never>?
    /// 每轮同步后等待 15 秒再尝试补拉的循环任务。
    private var timer: Task<Void, Never>?
    /// 是否正在处理发送队列，防止并发重复消费。
    private var flushingTask: Task<Void, Never>?
    private var flushingID: UUID?
    private var synchronizationID: UUID?
    private var lifecycle = UUID()
    private var stopping: (id: UUID, task: Task<Void, Never>)?
    /// 只保留最新 online 值的旧式变化订阅。
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    /// 只保留最新完整引擎状态的变化订阅。
    private var updateObservers: [UUID: AsyncStream<ChatEngineUpdate>.Continuation] = [:]
    /// 前台临时来信批次订阅，最多缓冲最近 16 批。
    private var incomingObservers: [UUID: AsyncStream<[ChatMessage]>.Continuation] = [:]
    /// 控制前台切换基线和迟到补拉是否可触发提醒的门控状态。
    private var notificationGate = ChatIncomingNotificationGate()
    /// 最近业务操作发布的在线观察值，初始为 false。
    private var online = false
    /// 最近完整补拉的状态，初始为 idle。
    private var synchronization: ChatSynchronizationState = .idle
    /// 同步过程中观察到的最大本人资料版本，初始为 0。
    private var ownProfileVersion: Int64 = 0
    /// 绑定聊天存储及共享会话，并创建 IM 与实时适配器；不自动启动同步。
    public init(store: ChatStore, session: APISessionManager) {
        self.store = store
        api = IMAPI(session: session)
        realtime = IMRealtimeClient(sessionManager: session)
    }
    /// 立即提交当前 online 观察值并订阅后续通知；缓冲只保留最新一项。
    public func changes() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(online)
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    /// 移除已结束的旧式连接观察订阅。
    private func remove(_ id: UUID) { observers[id] = nil }
    /// 立即提供当前状态，随后合并通知；订阅本身不将同步标记为成功。
    public func updates() -> AsyncStream<ChatEngineUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChatEngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateObservers[id] = continuation
        continuation.yield(.init(online: online, synchronization: synchronization, ownProfileVersion: ownProfileVersion))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeUpdateObserver(id) } }
        return stream
    }
    /// 移除已结束的完整状态订阅。
    private func removeUpdateObserver(_ id: UUID) { updateObservers[id] = nil }
    /// 将连接观察值、同步状态及本人资料版本作为同一快照广播。
    private func publishUpdate(scope: ChatChangeScope = [], conversations: Set<String>? = nil) {
        let value = ChatEngineUpdate(online: online, synchronization: synchronization,
            ownProfileVersion: ownProfileVersion, scope: scope, conversations: conversations)
        for observer in updateObservers.values {
            // 覆盖缓冲通知时合并业务范围，避免状态通知丢掉尚未消费的数据改变。
            if case .dropped(let old) = observer.yield(value) {
                var merged = value
                merged.scope.formUnion(old.scope)
                if !old.scope.isEmpty {
                    merged.conversations = old.conversations.flatMap { oldIDs in
                        if value.scope.isEmpty { return oldIDs }
                        return value.conversations.map { oldIDs.union($0) }
                    }
                }
                observer.yield(merged)
            }
        }
    }
    private func notify(_ online: Bool, scope: ChatChangeScope = .all, conversation: String? = nil) {
        self.online = online
        for observer in observers.values { observer.yield(online) }
        publishUpdate(scope: scope, conversations: conversation.map { [$0] })
    }
    /// 前台提醒是临时事件；首次进入前台完成的补拉只建立基线。
    public func setForegroundNotificationsEnabled(_ enabled: Bool) {
        notificationGate.setEnabled(enabled)
    }
    /// 订阅前台同步产生的临时消息批次；缓冲至多 16 批，不替代持久同步游标。
    public func incomingMessages() -> AsyncStream<[ChatMessage]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[ChatMessage]>.makeStream(bufferingPolicy: .bufferingNewest(16))
        incomingObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeIncomingObserver(id) } }
        return stream
    }
    /// 移除已结束的临时来信批次订阅。
    private func removeIncomingObserver(_ id: UUID) { incomingObservers[id] = nil }
    /// 启动实时提示监听和周期补拉；已启动时直接返回，实际同步结果通过状态流发布。
    public func start() async {
        if let stopping { await stopping.task.value; finishStopping(stopping.id) }
        guard !running else { return }
        running = true
        signals = Task { [weak self, realtime] in
            let stream = await realtime.syncSignals()
            await realtime.start()
            for await _ in stream {
                guard !Task.isCancelled else { break }
                try? await self?.synchronize()
            }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.synchronize()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
    }
    /// 关闭前台提醒，取消提示、定时和补拉任务并停止实时连接；保留存储及 outbox。
    public func stop() async {
        if let stopping { await stopping.task.value; finishStopping(stopping.id); return }
        notificationGate.setEnabled(false)
        running = false
        lifecycle = UUID()
        let tasks = (signals, timer, syncing, flushingTask)
        tasks.0?.cancel(); tasks.1?.cancel(); tasks.2?.cancel(); tasks.3?.cancel()
        let realtime = realtime
        let drain = Task {
            await realtime.stop()
            _ = try? await tasks.2?.value
            await tasks.3?.value
            await tasks.0?.value
            await tasks.1?.value
        }
        let stopID = UUID()
        stopping = (stopID, drain)
        await drain.value
        finishStopping(stopID)
    }
    private func finishStopping(_ id: UUID) {
        guard stopping?.id == id else { return }
        signals = nil; timer = nil; syncing = nil; flushingTask = nil
        synchronizationID = nil; flushingID = nil
        synchronization = .idle
        stopping = nil
        publishUpdate()
    }

    /// 共享一次完整补拉，发布同步成功或失败状态；成功后尝试处理发送队列。
    ///
    /// - Throws: 同步或取消错误；发送队列内部失败由 flush 记录，不作为本方法错误抛出。
    public func synchronize() async throws {
        guard stopping == nil else { throw CancellationError() }
        if let syncing { return try await syncing.value }
        let id = UUID(), generation = lifecycle
        synchronizationID = id
        synchronization = .syncing
        publishUpdate()
        let task = Task { try await self.pull() }
        syncing = task
        defer { if synchronizationID == id { syncing = nil; synchronizationID = nil } }
        do {
            try await task.value
            try Task.checkCancellation()
            guard lifecycle == generation, synchronizationID == id else { throw CancellationError() }
            synchronization = .synced
            notify(true, scope: [])
            await flush()
        } catch {
            guard lifecycle == generation else { throw CancellationError() }
            if error is CancellationError || Task.isCancelled {
                if synchronizationID == id { synchronization = .idle; publishUpdate() }
                throw CancellationError()
            }
            synchronization = .failed
            notify(false, scope: [])
            throw error
        }
    }
    /// 恢复同步基线并拉取增量，检查会话列表可见性，再按前台门控发布新来信批次。
    private func pull() async throws {
        try Task.checkCancellation()
        let checkpoint = try await store.checkpoint()
        let notificationPull = notificationGate.begin(hasCheckpoint: checkpoint != nil)
        var received: [ChatMessage] = []
        let expired = try await store.expireReedits()
        if !expired.isEmpty { publishUpdate(scope: [.messages], conversations: expired) }
        let needsContactUpgrade = try await store.contacts().contains { $0.semanticsVersion < 2 }
        if checkpoint == nil || needsContactUpgrade { try await snapshot() }
        do { received = try await events() } catch APIClientError.service(let error)
            where error.code == .cursorExpired
        {
            try await snapshot()
            _ = try await events()
        }
        try Task.checkCancellation()
        try await inspectConversationLists()
        try Task.checkCancellation()
        if notificationGate.complete(notificationPull), !received.isEmpty {
            for observer in incomingObservers.values { observer.yield(received) }
        }
    }
    /// 摘要为系统消息时检查历史，直到找到可显示内容或穷尽当前成员范围。
    private func inspectConversationLists() async throws {
        let states = try await store.conversationListStates()
        for conversation in try await store.conversations() {
            let state = states[conversation.id] ?? .init()
            guard !state.isVisible,
                  state.inspectedThrough != conversation.latest || state.inspectedBoundary != conversation.boundaryRevision,
                  conversation.latest > (state.hiddenThrough ?? 0) else { continue }
            do {
                var before: Int64 = 0, upper: Int64 = 0, boundary: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let page = try await api.history(conversation.id, before: before, upper: upper, boundary: boundary)
                    try Task.checkCancellation()
                    try await store.apply(history: page, conversation: conversation.id, restoringListVisibility: true)
                    let updated = try await store.conversationListStates()[conversation.id] ?? .init()
                    if updated.isVisible || !page.hasMore || page.before <= (updated.hiddenThrough ?? 0) { break }
                    guard page.before > 0, before == 0 || page.before < before else { throw APIClientError.invalidResponse }
                    before = page.before; upper = page.upper; boundary = page.boundary
                }
                try await store.finishListInspection(conversation)
                publishUpdate(scope: [.conversations, .messages], conversations: [conversation.id])
            } catch {
                if Task.isCancelled { throw CancellationError() }
                // 未核实的边界留待下次同步重试；历史查询失败不能阻断正常收发队列。
            }
        }
    }
    /// 逐页获取并保存联系人与会话快照，直到服务端标记 complete。
    private func snapshot() async throws {
        var token = ""
        var cursor = ""
        repeat {
            try Task.checkCancellation()
            let page = try await api.snapshot(token: token, cursor: cursor)
            try Task.checkCancellation()
            try await store.apply(snapshot: page)
            publishUpdate(scope: .all)
            if page.complete { break }
            token = page.token
            cursor = page.nextCursor
        } while true
    }
    /// 从本地检查点逐页补拉并事务提交增量，累计首次入库的他人消息及本人资料版本提示。
    private func events() async throws -> [ChatMessage] {
        var received: [ChatMessage] = []
        while let checkpoint = try await store.checkpoint() {
            try Task.checkCancellation()
            let batch = try await api.events(cursor: checkpoint.cursor, epoch: checkpoint.epoch)
            try Task.checkCancellation()
            received += try await store.apply(events: batch, expected: checkpoint)
            ownProfileVersion = max(ownProfileVersion, batch.ownProfileVersion ?? 0)
            var scope: ChatChangeScope = []
            var affected = Set<String>()
            for event in batch.events {
                if event.contact != nil { scope.insert(.directory) }
                if let conversation = event.conversation { scope.insert(.conversations); affected.insert(conversation.id) }
                if let message = event.message { scope.formUnion([.messages, .conversations]); affected.insert(message.conversationID) }
            }
            publishUpdate(scope: scope, conversations: affected)
            if !batch.hasMore { break }
        }
        return received
    }
    /// 获取一页历史并将消息和连续覆盖区间保存到本地；参数沿用 IMAPI.history 的序列语义。
    public func history(
        _ conversation: String, before: Int64 = 0, upper: Int64 = 0, boundary: Int64 = 0
    ) async throws
        -> ChatHistory
    {
        let generation = lifecycle
        let page = try await api.history(
            conversation, before: before, upper: upper, boundary: boundary)
        try Task.checkCancellation()
        guard lifecycle == generation else { throw CancellationError() }
        try await store.apply(history: page, conversation: conversation)
        notify(true, scope: [.messages], conversation: conversation)
        return page
    }
    /// 以当前本地身份创建消息并持久入队，清空文字草稿后尝试发送；返回不保证服务端已接收。
    public func send(
        conversation: String, text: String = "", kind: String = "text", assets: [String] = []
    ) async throws {
        let credentials = try await api.session.localIdentity()
        guard credentials.userID == store.userID else { throw ChatStoreError.scopeMismatch }
        let outgoing = ChatOutgoing(
            conversationID: conversation, deviceID: credentials.deviceID, kind: kind, text: text,
            assets: assets)
        try await store.enqueue(outgoing)
        try await store.saveDraft(.init(), conversation: conversation)
        notify(true, scope: [.messages, .conversations], conversation: conversation)
        await flush()
    }
    /// 保留原消息身份，将失败状态改为 waiting 并清除失败码，然后尝试发送队列。
    public func retry(_ pending: ChatPendingMessage) async throws {
        var pending = pending
        pending.state = "waiting"
        pending.failure = nil
        try await store.update(pending)
        await flush()
    }
    /// 使用持久化操作身份撤回消息；恢复副本失败不阻断网络撤回。
    ///
    /// - Returns: 已确认撤回的消息，以及本机是否仍可重新编辑其文本。
    public func revoke(_ message: ChatMessage, fallbackOperationID: UUID) async throws -> (
        message: ChatMessage, canReedit: Bool
    ) {
        let identity = try await api.session.localIdentity()
        guard identity.userID == store.userID,
            message.senderID == store.userID.uuidString.lowercased()
        else { throw ChatStoreError.scopeMismatch }
        let prepared = try? await store.prepareRevoke(message, operationID: fallbackOperationID)
        let value: ChatMessage
        do {
            value = try await api.revoke(
                conversation: message.conversationID, message: message.id,
                operationID: prepared?.operationID ?? fallbackOperationID)
        } catch {
            if let known = try? await store.messages(message.conversationID).first(where: { $0.id == message.id && $0.revoked }) {
                let available = (try? await store.reeditText(message: known.id, conversation: known.conversationID)) != nil
                notify(true, scope: [.messages, .conversations], conversation: message.conversationID)
                return (known, available)
            }
            if case APIClientError.service(let failure) = error,
                (400..<500).contains(failure.statusCode),
                ![401, 408, 409, 429].contains(failure.statusCode)
                    || failure.code == .revokeWindowExpired
            {
                try? await store.rejectRevoke(message: message.id)
            }
            // 丢失响应时仍由 HTTP 增量/历史确认，不能把网络失败解释为撤回失败。
            notify(false, scope: [.messages, .conversations], conversation: message.conversationID)
            throw error
        }
        guard value.id == message.id, value.conversationID == message.conversationID, value.revoked
        else { throw APIClientError.invalidResponse }
        // 已获服务端成功即保留成功语义；本机存储失败由后续同步补齐。
        try? await store.save(value)
        let available =
            (try? await store.reeditText(message: value.id, conversation: value.conversationID))
            != nil
        notify(true, scope: [.messages, .conversations], conversation: message.conversationID)
        return (value, available)
    }
    /// 按持久顺序尝试发送非 failed 任务；网络结果不确定时保留 confirming，失败时停止本轮。
    public func flush() async {
        guard stopping == nil else { return }
        if let flushingTask { await flushingTask.value; return }
        let id = UUID()
        flushingID = id
        let task = Task { await self.performFlush() }
        flushingTask = task
        await task.value
        if flushingID == id { flushingTask = nil; flushingID = nil }
    }
    private func performFlush() async {
        do {
            for var pending in try await store.pending() where pending.state != "failed" {
                try Task.checkCancellation()
                guard try await store.canTransmit(pending.outgoing) else { continue }
                pending.state = pending.state == "waiting" ? "sending" : "confirming"
                try await store.update(pending)
                notify(true, scope: [.messages], conversation: pending.outgoing.conversationID)
                do {
                    let result = try await api.send(pending.outgoing)
                    try Task.checkCancellation()
                    try await store.save(result)
                    notify(true, scope: [.messages, .conversations], conversation: pending.outgoing.conversationID)
                } catch {
                    try Task.checkCancellation()
                    pending.state = "confirming"
                    if case APIClientError.service(let failure) = error,
                        (400..<500).contains(failure.statusCode),
                        failure.statusCode != 429
                    {
                        pending.state = "failed"
                        pending.failure = failure.code.rawValue
                    }
                    try await store.update(pending)
                    notify(false, scope: [.messages], conversation: pending.outgoing.conversationID)
                    break
                }
            }
        } catch { if !(error is CancellationError), !Task.isCancelled { notify(false, scope: []) } }
    }
    /// 只推进本机已连续持久化覆盖且实际阅读的范围。
    public func markRead(_ conversation: ChatConversation, visibleThrough: Int64) async throws {
        guard
            let member = conversation.members.first(where: {
                $0.id == store.userID.uuidString.lowercased()
            })
        else {
            return
        }
        let from = member.intervals.first?.joined ?? 1
        let covered = try await store.coveredThrough(
            conversation: conversation.id, boundary: conversation.boundaryRevision, from: from)
        let through = min(visibleThrough, covered)
        guard through > conversation.readState.read else { return }
        let result = try await api.watermark(
            conversation: conversation.id, through: through, read: true, operationID: UUID())
        try await store.save(result)
        notify(true, scope: [.conversations], conversation: conversation.id)
    }
    /// 发布本地数据变化并将 online 观察值设为 true；不执行网络连通性检查或同步。
    public func changed(conversation: String? = nil, scope: ChatChangeScope = .all) { notify(true, scope: scope, conversation: conversation) }
    /// 取消提示、定时和补拉任务，并结束旧式 changes 订阅。
    deinit {
        signals?.cancel()
        timer?.cancel()
        syncing?.cancel()
        flushingTask?.cancel()
        for o in observers.values { o.finish() }
        for o in updateObservers.values { o.finish() }
        for o in incomingObservers.values { o.finish() }
    }
}
