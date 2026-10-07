import AzureFishAPI
import Foundation
import GRDB
import AzureFishStorage

public enum ChatStoreError: Error, Sendable, Equatable {
    case invalidKey, scopeMismatch, cursorMismatch, unavailable, invalidCoverage, transferCancelled
    case reeditExpired, draftChanged, incompatibleSchema
}
public struct ChatCheckpoint: Codable, Sendable {
    /// 已持久化的增量同步游标，不从实时提示直接推进。
    public var cursor: String
    /// 与游标对应的服务端同步代次。
    public var epoch: String
    /// 保存同步游标及服务端代次，不校验游标也不写入数据库。
    public init(cursor: String, epoch: String) { self.cursor = cursor; self.epoch = epoch }
}
public struct ChatPendingMessage: Codable, Sendable {
    /// 保留全部幂等身份及原始内容的待发消息。
    public let outgoing: ChatOutgoing
    /// 本机发送状态，如 waiting、sending、confirming 或 failed。
    public var state: String
    /// 本机首次入队时间，更新任务状态时不重设。
    public var createdAt: Date
    /// 最近明确业务失败的稳定错误码；nil 表示没有已记录错误码。
    public var failure: String?
}
public struct ChatLocalDraft: Codable, Sendable {
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    public var text: String
    /// 草稿关联的服务端媒体资产身份，保留顺序，默认空数组。
    public var assets: [String]
    /// 创建文字和资产列表草稿，默认均为空；不执行持久化。
    public init(text: String = "", assets: [String] = []) {
        self.text = text
        self.assets = assets
    }
}
/// 本机发起的撤回身份；恢复副本不可用时仍可使用同一操作撤回消息。
public struct ChatRevokeAttempt: Sendable {
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    public let operationID: UUID
    /// 本机是否保存了可恢复文字，不表示撤回已确认或恢复副本仍未过期。
    public let recoveryStored: Bool
}
/// 已确认撤回且尚未过期的本机编辑入口，不包含原消息正文。
public struct ChatReeditAvailability: Sendable {
    /// 所关联消息的稳定身份。
    public let messageID: String
    /// 本机重新编辑入口的截止时间，读取正文时仍需重新验证。
    public let expiresAt: Date
}
/// 聊天业务事务入口；可借用账号数据库，关闭借用实例不会关闭共享连接。
///
/// 实例业务访问在关闭后抛出 unavailable；底层数据库和映射错误向调用方传播。
/// 写入由账号数据库组织事务，失败回滚数据库内容；网络发送和文件删除使用各自的生命周期。
public actor ChatStore {
    /// 账号加密数据库；事务闭包不能挂起或让连接逃逸。
    let db: AccountDatabase
    /// 此聊天存储所属的用户身份。
    public nonisolated let userID: UUID
    /// 此聊天存储所属的服务环境标识。
    public nonisolated let environment: String
    /// 是否由本实例独占创建数据库；只有所有者关闭时才关闭底层连接。
    private let ownsDatabase: Bool
    /// 此聊天入口是否已结束访问；关闭后业务方法抛出 unavailable。
    private var closed = false
    /// 用于草稿活动、发送时间和重新编辑过期检查的可注入时钟。
    let now: @Sendable () -> Date

    /// 创建含当前业务基线的账号数据库；最终关闭由账号协调器负责。
    public nonisolated static func openDatabase(url: URL, key: Data, environment: String, userID: UUID,
                                                migrations: [AccountMigration] = []) throws -> AccountDatabase {
        do {
            let database = try AccountDatabase(url: url, key: key, environment: environment, userID: userID, baseline: ChatSchema.create, migrations: [mediaImportMigration] + migrations)
            try database.registerResourceReferences(domain: "chat") { db, id in try Self.hasImportReference(id, db: db) || ResourceReferences.all(in: db).contains(id) }
            return database
        }
        catch AccountStorageError.invalidKey { throw ChatStoreError.invalidKey }
        catch AccountStorageError.scopeMismatch { throw ChatStoreError.scopeMismatch }
        catch AccountStorageError.incompatibleSchema { throw ChatStoreError.incompatibleSchema }
    }
    /// 借用已包含聊天基线的账号数据库，注册资源引用查询并清理过期恢复副本。
    ///
    /// 不取得底层数据库的关闭所有权；初始化失败原样抛出存储错误。
    public init(database: AccountDatabase, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = database; userID = database.userID; environment = database.environment
        ownsDatabase = false; self.now = now
        try database.registerResourceReferences(domain: "chat") { db, id in try Self.hasImportReference(id, db: db) || ResourceReferences.all(in: db).contains(id) }
        try database.write { try Self.expireReedits(now: now(), db: $0) }
    }
    /// 为独立测试或单一所有者创建存储；关闭此实例会关闭它创建的数据库。
    public init(url: URL, key: Data, environment: String, userID: UUID, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try Self.openDatabase(url: url, key: key, environment: environment, userID: userID)
        self.userID = userID; self.environment = environment; self.now = now; ownsDatabase = true
        try db.write { try Self.expireReedits(now: now(), db: $0) }
    }
    /// 确认聊天入口尚未关闭；关闭后抛出 unavailable。
    func check() throws { guard !closed else { throw ChatStoreError.unavailable } }
    /// 结束此聊天入口的访问；仅 ownsDatabase 为 true 时关闭底层账号数据库。
    public func close() throws {
        if ownsDatabase { try db.close() }
        closed = true
    }
    /// 从同一数据库快照恢复全部联系人及关联资料；不保证结果排序。
    public func contacts() throws -> [ChatContact] {
        try check(); return try db.read { try DirectoryRepository.contacts(in: $0) }
    }
    /// 在同一次数据库读取中恢复通讯录与首次同步状态，不发起网络请求。
    public func contactDirectorySnapshot() throws -> (contacts: [ChatContact], hasSnapshot: Bool) {
        try check()
        return try db.read { (try DirectoryRepository.contacts(in: $0), try CheckpointRecord.fetchOne($0, key: "account_events") != nil) }
    }
    /// 从同一数据库快照恢复会话、成员、读状态和最新摘要；不保证结果排序。
    public func conversations(identifiers: Set<String>? = nil) throws -> [ChatConversation] {
        try check()
        return try db.read { db in
            if let identifiers { return try identifiers.sorted().compactMap { try DirectoryRepository.conversation($0, in: db) } }
            return try DirectoryRepository.conversations(in: db)
        }
    }
    /// 构造指定会话排除本机隐藏消息的查询；不额外验证成员权限或撤回状态。
    static func visibleMessages(_ conversation: String) -> QueryInterfaceRequest<MessageRecord> {
        MessageRecord.filter(MessageRecord.Columns.conversationID == conversation)
            .filter(!HiddenRecord.filter(HiddenRecord.Columns.hidden == true).select(HiddenRecord.Columns.messageID).contains(MessageRecord.Columns.id))
    }
    /// 优先读取权威摘要，尊重本机隐藏；摘要不会写入历史覆盖表。
    public func latestVisibleMessage(_ conversation: String) throws -> ChatMessage? {
        try check()
        return try db.read { db in
            let summary = try DirectoryRepository.conversation(conversation, in: db)?.latestMessage
            let local = try MessageRepository.fetch(Self.visibleMessages(conversation).order(MessageRecord.Columns.sequence.desc).limit(1), in: db).first
            let cutoff = try Self.localState(conversation, db: db).clearedThrough
            let hidden = Set(try HiddenRecord.filter(HiddenRecord.Columns.hidden == true).fetchAll(db).map(\.messageID))
            return [summary, local].compactMap { $0 }.filter { !hidden.contains($0.id) && $0.sequence > cutoff }.max {
                $0.sequence == $1.sequence ? $0.revision < $1.revision : $0.sequence < $1.sequence
            }
        }
    }
    /// 读取指定序列之前的本机未隐藏消息，按序列升序返回。
    ///
    /// - Parameters:
    ///   - conversation: 要读取的会话身份。
    ///   - before: 排他性的序列上界，默认不限制常规序列。
    ///   - limit: 请求条数，默认 100，实际限制在 1～200。
    /// - Returns: 至多 limit 经范围修正后的条数；成员权限及撤回展示由调用方另行处理。
    public func messages(_ conversation: String, before: Int64 = .max, limit: Int = 100) throws -> [ChatMessage] {
        try check()
        return try db.read { try MessageRepository.fetch(Self.visibleMessages(conversation)
            .filter(MessageRecord.Columns.sequence < before).order(MessageRecord.Columns.sequence.desc).limit(min(max(limit, 1), 200)), in: $0).reversed() }
    }
    /// 读取账号增量流检查点；尚未建立完整快照基线时返回 nil。
    public func checkpoint() throws -> ChatCheckpoint? {
        try check()
        return try db.read { try CheckpointRecord.fetchOne($0, key: "account_events").map { .init(cursor: $0.cursor, epoch: $0.epoch) } }
    }
    /// 在写入事务中替换账号增量检查点；调用方须确认对应实体已妥善保存。
    public func saveCheckpoint(_ value: ChatCheckpoint) throws {
        try check(); try db.write { try Self.checkpoint(value, db: $0) }
    }
    /// 在调用者事务中替换账号增量流的游标与同步代次。
    static func checkpoint(_ value: ChatCheckpoint, db: Database) throws {
        try CheckpointRecord(stream: "account_events", cursor: value.cursor, epoch: value.epoch).upsert(db)
    }
    /// 在同一事务合并本页联系人和会话；仅 complete 页保存快照基线检查点。
    public func apply(snapshot: ChatSnapshot) throws {
        try check()
        try db.write { db in
            for contact in snapshot.contacts { try Self.putContact(contact, db: db) }
            for conversation in snapshot.conversations { try Self.putConversation(conversation, userID: userID, db: db) }
            if snapshot.complete { try Self.checkpoint(.init(cursor: snapshot.baseline, epoch: snapshot.epoch), db: db) }
        }
    }
    /// 增量实体与游标同事务提交；返回首次入库的他人消息，展示前仍需复核可见性。
    @discardableResult
    public func apply(events: ChatEvents, expected: ChatCheckpoint) throws -> [ChatMessage] {
        try check()
        return try db.write { db in
            guard let current = try CheckpointRecord.fetchOne(db, key: "account_events"),
                  current.cursor == expected.cursor, current.epoch == expected.epoch,
                  events.epoch == expected.epoch, events.base == expected.cursor else { throw ChatStoreError.cursorMismatch }
            var incoming: [ChatMessage] = []
            for event in events.events {
                if let contact = event.contact { try Self.putContact(contact, db: db) }
                if let conversation = event.conversation { try Self.putConversation(conversation, userID: userID, db: db) }
                if let message = event.message {
                    let exists = try MessageRecord.fetchOne(db, key: message.id) != nil
                    try Self.putMessage(message, userID: userID, now: now(), restoreListVisibility: event.kind == "message" && !exists, db: db)
                    if event.kind == "message", !exists, !message.revoked, message.kind != "system", message.senderID != userID.uuidString.lowercased() { incoming.append(message) }
                }
            }
            try Self.checkpoint(.init(cursor: events.next, epoch: events.epoch), db: db)
            return incoming
        }
    }
    /// 在事务中分别按关系和公开资料版本合并联系人快照。
    public func save(_ contact: ChatContact) throws {
        try check(); try db.write { try Self.putContact(contact, db: $0) }
    }
    /// 在事务中合并会话及读状态版本，并更新最新摘要和本机列表活动。
    public func save(_ conversation: ChatConversation) throws {
        try check(); try db.write { try Self.putConversation(conversation, userID: userID, db: $0) }
    }
    /// 在事务中合并消息与回执版本，并处理撤回、发送确认、资源清理及搜索索引。
    public func save(_ message: ChatMessage) throws {
        try check(); try db.write { try Self.putMessage(message, userID: userID, now: now(), db: $0) }
    }
    /// 历史与连续覆盖范围同事务保存；普通分页不恢复隐藏会话。
    public func apply(history: ChatHistory, conversation: String, restoringListVisibility: Bool = false) throws {
        try check()
        try db.write { db in
            for message in history.messages { try Self.putMessage(message, userID: userID, now: now(), restoreListVisibility: restoringListVisibility, db: db) }
            if history.coveredFrom > 0 {
                guard history.coveredThrough >= history.coveredFrom else { throw ChatStoreError.invalidCoverage }
                try HistoryRangeRecord(id: nil, conversationID: conversation, boundary: history.boundary,
                    lower: history.coveredFrom, upper: history.coveredThrough).insert(db)
            }
        }
    }
    /// 计算指定边界版本下从 from 开始连续持久化的最大序列，遇到首个缺口即停止。
    public func coveredThrough(conversation: String, boundary: Int64, from: Int64) throws -> Int64 {
        try check()
        return try db.read { db in
            var through = from - 1
            for row in try HistoryRangeRecord.filter(HistoryRangeRecord.Columns.conversationID == conversation)
                .filter(HistoryRangeRecord.Columns.boundary == boundary).order(HistoryRangeRecord.Columns.lower).fetchAll(db) {
                if row.lower <= through + 1 { through = max(through, row.upper) } else { break }
            }
            return max(0, through)
        }
    }
    /// 按关系版本和公开资料版本分别合并联系人，再写入调用者事务。
    static func putContact(_ incoming: ChatContact, db: Database) throws {
        let old = try DirectoryRepository.contacts(peer: incoming.peer.id, in: db).first
        try DirectoryRepository.save(old?.merging(incoming) ?? incoming, in: db)
    }
    /// 合并会话、读摘要及公共资料版本，维护最新摘要与本机列表活动状态。
    static func putConversation(_ incoming: ChatConversation, userID: UUID, db: Database) throws {
        for member in incoming.members { try DirectoryRepository.profile(member.profile, in: db) }
        var value = incoming
        if let old = try DirectoryRepository.conversation(value.id, in: db) {
            if old.revision > value.revision {
                value = old
                if incoming.readState.revision > value.readState.revision {
                    value.readState = incoming.readState; value.latest = incoming.latest; value.latestMessage = incoming.latestMessage
                }
            } else if old.readState.revision > value.readState.revision {
                value.readState = old.readState; value.latest = old.latest; value.latestMessage = old.latestMessage
            }
            if value.latestMessage == nil, value.latest == old.latest { value.latestMessage = old.latestMessage }
            if let previous = old.latestMessage, let current = value.latestMessage,
               previous.id == current.id && (previous.revision > current.revision || previous.revoked) { value.latestMessage = previous }
        }
        if let message = value.latestMessage, message.revoked { try invalidateMedia(message: message.id, db: db) }
        try DirectoryRepository.save(value, in: db)
        if let message = value.latestMessage { try recordListMessage(message, userID: userID, restoreHidden: true, db: db) }
    }
    /// 校验固定消息身份并合并内容及回执版本，协调撤回、媒体清理、outbox 和搜索索引。
    static func putMessage(_ incoming: ChatMessage, userID: UUID, now: Date, restoreListVisibility: Bool? = nil, db: Database) throws {
        let old = try MessageRepository.one(incoming.id, in: db)
        var value = incoming
        if let old {
            guard old.conversationID == incoming.conversationID, old.clientID == incoming.clientID,
                  old.serverID == incoming.serverID, old.senderID == incoming.senderID,
                  old.deviceID == incoming.deviceID, old.sequence == incoming.sequence else { throw ChatStoreError.scopeMismatch }
            if old.revision > value.revision || old.revoked {
                value = old
                if incoming.receipt.revision > old.receipt.revision { value.receipt = incoming.receipt }
            } else if old.receipt.revision > value.receipt.revision { value.receipt = old.receipt }
        }
        if value.revoked {
            try invalidateMedia(message: value.id, resources: (old?.assets ?? []).flatMap(\.resources).map(\.id), db: db)
            value.text = ""; value.textRuns = nil; value.linkURL = nil; value.assets = []
        }
        try MessageRepository.save(value, in: db)
        try recordListMessage(value, userID: userID, restoreHidden: restoreListVisibility ?? (old == nil), db: db)
        try expireReedits(now: now, db: db)
        if value.revoked, value.senderID == userID.uuidString.lowercased(),
           var recovery = try ReeditRecord.fetchOne(db, key: value.id), recovery.conversationID == value.conversationID,
           recovery.state == "pending", recovery.text != nil {
            recovery.state = "confirmed"; recovery.expires = now.addingTimeInterval(180).timeIntervalSince1970
            try recovery.update(db)
        }
        if value.sequence <= (try localState(value.conversationID, db: db)).clearedThrough {
            try HiddenRecord(messageID: value.id, hidden: true).upsert(db)
        }
        try retireSendResources(value.id, db: db)
        try SendTaskRecord.deleteOne(db, key: value.id)
        try SendOrderRecord.filter(SendOrderRecord.Columns.messageID == value.id).deleteAll(db)
        try SearchRepository.remove(value.id, in: db)
        if !value.revoked, value.schemaVersion == 1, ["text", "link"].contains(value.kind), try HiddenRecord.fetchOne(db, key: value.id)?.hidden != true {
            try SearchRepository.index(value, in: db)
        }
    }
}

/// 一次发送中按编辑器顺序排列的消息或媒体上传占位。
public enum ChatCompositionItem: Sendable {
    case message(ChatOutgoing)
    case upload(ChatUploadBatch)
}
