import AzureFishAPI
import Foundation

/// 全量快照与增量补拉的状态；本地消息变化不表示同步完成。
public enum ChatSynchronizationState: Sendable, Equatable {
    case idle, syncing, synced, failed
}

/// 聊天数据变化时携带的连接观察值与独立同步状态。
public struct ChatEngineUpdate: Sendable, Equatable {
    public let online: Bool
    public let synchronization: ChatSynchronizationState
}

/// 驱动账号隔离的 HTTP 同步和持久 outbox；WebSocket 只唤醒 HTTP 补拉。
public actor ChatEngine {
    public nonisolated let store: ChatStore
    public nonisolated let api: IMAPI
    private let realtime: IMRealtimeClient
    private var running = false
    private var syncing: Task<Void, Error>?
    private var signals: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var flushing = false
    private var observers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var updateObservers: [UUID: AsyncStream<ChatEngineUpdate>.Continuation] = [:]
    private var online = false
    private var synchronization: ChatSynchronizationState = .idle
    public init(store: ChatStore, session: APISessionManager) {
        self.store = store
        api = IMAPI(session: session)
        realtime = IMRealtimeClient(sessionManager: session)
    }
    public func changes() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(online)
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        return stream
    }
    private func remove(_ id: UUID) { observers[id] = nil }
    /// 立即提供当前状态，随后合并通知；订阅本身不将同步标记为成功。
    public func updates() -> AsyncStream<ChatEngineUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ChatEngineUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updateObservers[id] = continuation
        continuation.yield(.init(online: online, synchronization: synchronization))
        continuation.onTermination = { [weak self] _ in Task { await self?.removeUpdateObserver(id) } }
        return stream
    }
    private func removeUpdateObserver(_ id: UUID) { updateObservers[id] = nil }
    private func publishUpdate() {
        let value = ChatEngineUpdate(online: online, synchronization: synchronization)
        for observer in updateObservers.values { observer.yield(value) }
    }
    private func notify(_ online: Bool) {
        self.online = online
        for observer in observers.values { observer.yield(online) }
        publishUpdate()
    }
    public func start() async {
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
    public func stop() async {
        running = false
        signals?.cancel()
        timer?.cancel()
        syncing?.cancel()
        signals = nil
        timer = nil
        syncing = nil
        await realtime.stop()
    }
    public func synchronize() async throws {
        if let syncing { return try await syncing.value }
        synchronization = .syncing
        publishUpdate()
        let task = Task { try await self.pull() }
        syncing = task
        defer { syncing = nil }
        do {
            try await task.value
            try Task.checkCancellation()
            synchronization = .synced
            notify(true)
            await flush()
        } catch {
            synchronization = .failed
            notify(false)
            throw error
        }
    }
    private func pull() async throws {
        try await store.expireReedits()
        if try await store.checkpoint() == nil { try await snapshot() }
        do { try await events() } catch APIClientError.service(let error)
            where error.code == .cursorExpired
        {
            try await snapshot()
            try await events()
        }
    }
    private func snapshot() async throws {
        var token = ""
        var cursor = ""
        repeat {
            try Task.checkCancellation()
            let page = try await api.snapshot(token: token, cursor: cursor)
            try await store.apply(snapshot: page)
            if page.complete { break }
            token = page.token
            cursor = page.nextCursor
        } while true
    }
    private func events() async throws {
        while let checkpoint = try await store.checkpoint() {
            try Task.checkCancellation()
            let batch = try await api.events(cursor: checkpoint.cursor, epoch: checkpoint.epoch)
            try await store.apply(events: batch, expected: checkpoint)
            if !batch.hasMore { break }
        }
    }
    public func history(
        _ conversation: String, before: Int64 = 0, upper: Int64 = 0, boundary: Int64 = 0
    ) async throws
        -> ChatHistory
    {
        let page = try await api.history(
            conversation, before: before, upper: upper, boundary: boundary)
        try await store.apply(history: page, conversation: conversation)
        notify(true)
        return page
    }
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
        notify(true)
        await flush()
    }
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
                notify(true)
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
            notify(false)
            throw error
        }
        guard value.id == message.id, value.conversationID == message.conversationID, value.revoked
        else { throw APIClientError.invalidResponse }
        // 已获服务端成功即保留成功语义；本机存储失败由后续同步补齐。
        try? await store.save(value)
        let available =
            (try? await store.reeditText(message: value.id, conversation: value.conversationID))
            != nil
        notify(true)
        return (value, available)
    }
    public func flush() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        do {
            for var pending in try await store.pending() where pending.state != "failed" {
                try Task.checkCancellation()
                guard try await store.canTransmit(pending.outgoing) else { continue }
                pending.state = pending.state == "waiting" ? "sending" : "confirming"
                try await store.update(pending)
                notify(true)
                do {
                    let result = try await api.send(pending.outgoing)
                    try await store.save(result)
                    notify(true)
                } catch {
                    pending.state = "confirming"
                    if case APIClientError.service(let failure) = error,
                        (400..<500).contains(failure.statusCode),
                        failure.statusCode != 429
                    {
                        pending.state = "failed"
                        pending.failure = failure.code.rawValue
                    }
                    try await store.update(pending)
                    notify(false)
                    break
                }
            }
        } catch { notify(false) }
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
        notify(true)
    }
    public func changed() { notify(true) }
    deinit {
        signals?.cancel()
        timer?.cancel()
        syncing?.cancel()
        for o in observers.values { o.finish() }
    }
}
