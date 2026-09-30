import AzureFishAPI
import Foundation
import GRDB

public enum ChatStoreError: Error, Sendable, Equatable {
    case invalidKey, scopeMismatch, cursorMismatch, unavailable, invalidCoverage, transferCancelled
    case reeditExpired, draftChanged
}
public struct ChatCheckpoint: Codable, Sendable {
    public var cursor: String
    public var epoch: String
}
public struct ChatPendingMessage: Codable, Sendable {
    public let outgoing: ChatOutgoing
    public var state: String
    public var createdAt: Date
    public var failure: String?
}
public struct ChatLocalDraft: Codable, Sendable {
    public var text: String
    public var assets: [String]
    public init(text: String = "", assets: [String] = []) {
        self.text = text
        self.assets = assets
    }
}
/// 本机发起的撤回身份；恢复副本不可用时仍可使用同一操作撤回消息。
public struct ChatRevokeAttempt: Sendable {
    public let operationID: UUID
    public let recoveryStored: Bool
}
/// 已确认撤回且尚未过期的本机编辑入口，不包含原消息正文。
public struct ChatReeditAvailability: Sendable {
    public let messageID: String
    public let expiresAt: Date
}
/// 每个环境及账号独占的 SQLCipher 库；调用者从 Keychain 提供独立随机密钥。
public actor ChatStore {
    let db: DatabaseQueue
    public nonisolated let userID: UUID
    public nonisolated let environment: String
    private var closed = false
    private let now: @Sendable () -> Date
    public init(
        url: URL, key: Data, environment: String, userID: UUID,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.now = now
        guard key.count == 32 else { throw ChatStoreError.invalidKey }
        self.environment = environment
        self.userID = userID
        var configuration = Configuration()
        configuration.prepareDatabase { db in try db.usePassphrase(key.base64EncodedString()) }
        let existed = FileManager.default.fileExists(atPath: url.path)
        db = try DatabaseQueue(path: url.path, configuration: configuration)
        let expectedScope = Data((environment + ":" + userID.uuidString.lowercased()).utf8)
        if existed {
            try db.read { db in
                guard try db.tableExists("meta"),
                    try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='scope'")
                        == expectedScope
                else { throw ChatStoreError.scopeMismatch }
            }
        }
        var migrations = DatabaseMigrator()
        migrations.registerMigration("chat-v1") { db in
            try db.execute(sql: "CREATE TABLE meta (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try db.execute(
                sql:
                    "CREATE TABLE entity (bucket TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL, conversation TEXT NOT NULL DEFAULT '', sequence INTEGER NOT NULL DEFAULT 0, payload BLOB NOT NULL, PRIMARY KEY(bucket,id))"
            )
            try db.execute(
                sql: "CREATE INDEX messages_by_conversation ON entity(bucket,conversation,sequence)"
            )
            try db.execute(sql: "CREATE TABLE outbox (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE draft (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE hidden (id TEXT PRIMARY KEY)")
            try db.execute(
                sql:
                    "CREATE TABLE coverage (conversation TEXT NOT NULL, boundary INTEGER NOT NULL, lower INTEGER NOT NULL, upper INTEGER NOT NULL)"
            )
            try db.execute(
                sql: "CREATE TABLE transfer (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try db.execute(
                sql: "CREATE VIRTUAL TABLE message_search USING fts5(id UNINDEXED, body)")
        }
        migrations.registerMigration("chat-v2-revoke-recovery") { db in
            try db.execute(
                sql:
                    "CREATE TABLE revoke_recovery (id TEXT PRIMARY KEY, conversation TEXT NOT NULL, operation TEXT NOT NULL, state TEXT NOT NULL, text TEXT, expires REAL NOT NULL)"
            )
        }
        migrations.registerMigration("chat-v3-composition-order") { db in
            try db.execute(sql: "CREATE TABLE delivery_order (position INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT UNIQUE NOT NULL, conversation TEXT NOT NULL)")
            try db.execute(sql: "ALTER TABLE revoke_recovery ADD COLUMN runs BLOB")
            let pending = try Data.fetchAll(db, sql: "SELECT payload FROM outbox").map { try JSONDecoder().decode(ChatPendingMessage.self, from: $0) }
            let transfers = try Data.fetchAll(db, sql: "SELECT payload FROM transfer").map { try JSONDecoder().decode(ChatUploadBatch.self, from: $0) }
            let ordered = pending.map { ($0.createdAt, $0.outgoing.id, $0.outgoing.conversationID) }
                + transfers.map { ($0.createdAt, $0.messageID, $0.conversation) }
            for item in ordered.sorted(by: { $0.0 < $1.0 }) {
                try Self.order(item.1, conversation: item.2, db: db)
            }
        }
        migrations.registerMigration("chat-v4-local-details-search") { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS conversation_clear (conversation TEXT PRIMARY KEY, sequence INTEGER NOT NULL)")
            try db.execute(sql: "DROP TABLE message_search")
            try db.execute(sql: "CREATE VIRTUAL TABLE message_search USING fts5(id UNINDEXED, body, tokenize='ascii')")
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND id NOT IN (SELECT id FROM hidden)") {
                let message = try JSONDecoder().decode(ChatMessage.self, from: data)
                if !message.revoked && ["text", "link"].contains(message.kind) {
                    try db.execute(sql: "INSERT INTO message_search VALUES (?,?)", arguments: [message.id, ChatSearchTokenizer.tokens(message.text).joined(separator: " ")])
                }
            }
        }
        migrations.registerMigration("chat-v5-conversation-list") { db in
            try Self.migrateConversationList(db, userID: userID)
        }
        try migrations.migrate(db)
        let scope = Data((environment + ":" + userID.uuidString.lowercased()).utf8)
        try db.write { db in
            guard try String.fetchOne(db, sql: "PRAGMA cipher_version")?.isEmpty == false else {
                throw ChatStoreError.invalidKey
            }
            if let existing = try Data.fetchOne(
                db, sql: "SELECT payload FROM meta WHERE id='scope'")
            {
                guard existing == scope else { throw ChatStoreError.scopeMismatch }
            } else {
                try db.execute(sql: "INSERT INTO meta VALUES ('scope', ?)", arguments: [scope])
            }
            try Self.expireReedits(now: now(), db: db)
        }
    }
    func check() throws { guard !closed else { throw ChatStoreError.unavailable } }
    public func close() throws {
        closed = true
        try db.close()
    }
    public func contacts() throws -> [ChatContact] {
        try check()
        return try db.read { try Self.readContacts($0) }
    }
    /// 在同一次数据库读取中恢复通讯录与首次同步状态，不发起网络请求。
    public func contactDirectorySnapshot() throws -> (contacts: [ChatContact], hasSnapshot: Bool) {
        try check()
        return try db.read { db in
            let checkpoint = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='checkpoint'")
                .map { try JSONDecoder().decode(ChatCheckpoint.self, from: $0) }
            return (try Self.readContacts(db), checkpoint != nil)
        }
    }
    private static func readContacts(_ db: Database) throws -> [ChatContact] {
        let profiles = try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='profile'")
            .map { try JSONDecoder().decode(ChatUser.self, from: $0) }
        let latest = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        return try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='contact'").map {
            var value = try JSONDecoder().decode(ChatContact.self, from: $0)
            if let profile = latest[value.peer.id], profile.version > value.peer.version { value.peer = profile }
            return value
        }
    }
    public func conversations() throws -> [ChatConversation] {
        let profiles: [ChatUser] = try values("profile")
        let latest = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let conversations: [ChatConversation] = try values("conversation")
        return conversations.map { conversation in
            var value = conversation
            value.members = value.members.map { member in
                var member = member
                if let profile = latest[member.id], profile.version > member.profile.version { member.profile = profile }
                return member
            }
            return value
        }
    }
    private func values<T: Decodable>(_ bucket: String) throws -> [T] {
        try check()
        return try db.read { db in
            try Data.fetchAll(
                db, sql: "SELECT payload FROM entity WHERE bucket=?", arguments: [bucket]
            ).map {
                try JSONDecoder().decode(T.self, from: $0)
            }
        }
    }
    /// 优先读取权威摘要，尊重本机隐藏；摘要不会写入历史覆盖表。
    public func latestVisibleMessage(_ conversation: String) throws -> ChatMessage? {
        try check()
        return try db.read { db in
            let hidden = Set(try String.fetchAll(db, sql: "SELECT id FROM hidden"))
            let data = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?", arguments: [conversation])
            let summary = try data.map { try JSONDecoder().decode(ChatConversation.self, from: $0) }.flatMap(\.latestMessage)
            let local = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND conversation=? AND id NOT IN (SELECT id FROM hidden) ORDER BY sequence DESC LIMIT 1", arguments: [conversation])
                .map { try JSONDecoder().decode(ChatMessage.self, from: $0) }
            let cutoff = try Int64.fetchOne(db, sql: "SELECT sequence FROM conversation_clear WHERE conversation=?", arguments: [conversation]) ?? 0
            let candidates = [summary, local].compactMap { $0 }.filter { !hidden.contains($0.id) && $0.sequence > cutoff }
            return candidates.max { lhs, rhs in
                lhs.sequence == rhs.sequence ? lhs.revision < rhs.revision : lhs.sequence < rhs.sequence
            }
        }
    }
    public func messages(_ conversation: String, before: Int64 = .max, limit: Int = 100) throws
        -> [ChatMessage]
    {
        try check()
        return try db.read { db in
            try Data.fetchAll(
                db,
                sql:
                    "SELECT payload FROM entity WHERE bucket='message' AND conversation=? AND sequence<? AND id NOT IN (SELECT id FROM hidden) ORDER BY sequence DESC LIMIT ?",
                arguments: [conversation, before, min(max(limit, 1), 200)]
            ).map { try JSONDecoder().decode(ChatMessage.self, from: $0) }.reversed()
        }
    }
    public func checkpoint() throws -> ChatCheckpoint? { try meta("checkpoint") }
    public func meta<T: Codable & Sendable>(_ id: String) throws -> T? {
        try check()
        return try db.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: [id]).map {
                try JSONDecoder().decode(T.self, from: $0)
            }
        }
    }
    public func setMeta<T: Codable & Sendable>(_ value: T, id: String) throws {
        try check()
        let data = try JSONEncoder().encode(value)
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: [id, data])
        }
    }
    /// 删除账号私有元数据，不影响其他业务实体或同步游标。
    public func removeMeta(_ id: String) throws {
        try check()
        try db.write { try $0.execute(sql: "DELETE FROM meta WHERE id=?", arguments: [id]) }
    }
    public func apply(snapshot: ChatSnapshot) throws {
        try check()
        try db.write { db in
            for contact in snapshot.contacts {
                try Self.putContact(contact, db: db)
            }
            for conversation in snapshot.conversations {
                try Self.putConversation(conversation, userID: userID, db: db)
            }
            if snapshot.complete {
                try Self.checkpoint(.init(cursor: snapshot.baseline, epoch: snapshot.epoch), db: db)
            }
        }
    }
    /// 原子保存增量与游标，返回本批首次入库的他人消息候选；展示前仍须复核可见性及偏好。
    @discardableResult
    public func apply(events: ChatEvents, expected: ChatCheckpoint) throws -> [ChatMessage] {
        try check()
        return try db.write { db in
            var incoming: [ChatMessage] = []
            let saved = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='checkpoint'")
            guard let saved,
                let current = try? JSONDecoder().decode(ChatCheckpoint.self, from: saved),
                current.cursor == expected.cursor, current.epoch == expected.epoch,
                events.epoch == expected.epoch, events.base == expected.cursor
            else { throw ChatStoreError.cursorMismatch }
            for event in events.events {
                if let contact = event.contact {
                    try Self.putContact(contact, db: db)
                }
                if let conversation = event.conversation {
                    try Self.putConversation(conversation, userID: userID, db: db)
                }
                if let message = event.message {
                    let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM entity WHERE bucket='message' AND id=?)", arguments: [message.id]) ?? false
                    try Self.putMessage(message, userID: userID, now: now(), restoreListVisibility: event.kind == "message" && !exists, db: db)
                    if event.kind == "message", !exists, !message.revoked, message.kind != "system", message.senderID != userID.uuidString.lowercased() {
                        incoming.append(message)
                    }
                }
            }
            try Self.checkpoint(.init(cursor: events.next, epoch: events.epoch), db: db)
            return incoming
        }
    }
    public func save(_ contact: ChatContact) throws {
        try check()
        try db.write {
            try Self.putContact(contact, db: $0)
        }
    }
    public func save(_ conversation: ChatConversation) throws {
        try check()
        try db.write { try Self.putConversation(conversation, userID: userID, db: $0) }
    }
    public func save(_ message: ChatMessage) throws {
        try check()
        try db.write { try Self.putMessage(message, userID: userID, now: now(), db: $0) }
    }
    /// 保存历史及连续覆盖范围；普通分页不恢复用户隐藏的会话。
    /// - Parameter restoringListVisibility: 仅同步器核实隐藏边界之后的新内容时传入 true。
    public func apply(history: ChatHistory, conversation: String, restoringListVisibility: Bool = false) throws {
        try check()
        try db.write { db in
            for message in history.messages {
                try Self.putMessage(message, userID: userID, now: now(), restoreListVisibility: restoringListVisibility, db: db)
            }
            if history.coveredFrom > 0 {
                guard history.coveredThrough >= history.coveredFrom else {
                    throw ChatStoreError.invalidCoverage
                }
                try db.execute(
                    sql: "INSERT INTO coverage VALUES (?,?,?,?)",
                    arguments: [
                        conversation, history.boundary, history.coveredFrom, history.coveredThrough,
                    ])
            }
        }
    }
    /// 仅返回从权限起点连续覆盖到的水位，不能用最大已见序号代替。
    public func coveredThrough(conversation: String, boundary: Int64, from: Int64) throws -> Int64 {
        try check()
        return try db.read { db in
            var through = from - 1
            for row in try Row.fetchAll(
                db,
                sql:
                    "SELECT lower,upper FROM coverage WHERE conversation=? AND boundary=? ORDER BY lower",
                arguments: [conversation, boundary])
            {
                let lower: Int64 = row["lower"]
                let upper: Int64 = row["upper"]
                if lower <= through + 1 { through = max(through, upper) } else { break }
            }
            return max(0, through)
        }
    }
    /// 将一次编辑拆分的文字和媒体任务原子入队，然后清除对应草稿。
    public func enqueueComposition(
        text: ChatOutgoing?, batches: [ChatUploadBatch], conversation: String
    ) throws {
        try enqueueComposition((text.map { [ChatCompositionItem.message($0)] } ?? []) + batches.map(ChatCompositionItem.upload), conversation: conversation)
    }
    /// 按编辑器顺序原子保存消息及上传占位；事务成功后才清除草稿。
    public func enqueueComposition(_ items: [ChatCompositionItem], conversation: String) throws {
        try check()
        guard !items.isEmpty else { throw ChatStoreError.unavailable }
        try db.write { db in
            for item in items {
                switch item {
                case .message(let message):
                    guard message.conversationID == conversation else { throw ChatStoreError.scopeMismatch }
                    let pending = ChatPendingMessage(outgoing: message, state: "waiting", createdAt: now(), failure: nil)
                    try db.execute(sql: "INSERT INTO outbox VALUES (?,?)", arguments: [message.id.uuidString.lowercased(), JSONEncoder().encode(pending)])
                    try Self.order(message.id, conversation: conversation, db: db)
                case .upload(let batch):
                    guard batch.conversation == conversation else { throw ChatStoreError.scopeMismatch }
                    try db.execute(sql: "INSERT INTO transfer VALUES (?,?)", arguments: [batch.id.uuidString, JSONEncoder().encode(batch)])
                    try Self.order(batch.messageID, conversation: conversation, db: db)
                }
            }
            try Self.recordListSend(conversation, at: now(), db: db)
            try db.execute(sql: "DELETE FROM draft WHERE id=?", arguments: [conversation])
            try db.execute(sql: "DELETE FROM meta WHERE id IN (?,?)", arguments: ["attachments:" + conversation, "rich-draft:" + conversation])
        }
    }
    private static func order(_ id: UUID, conversation: String, db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO delivery_order(message,conversation) VALUES (?,?)", arguments: [id.uuidString.lowercased(), conversation])
    }
    /// 仅允许同一会话队首发送，媒体处理、失败和重启不会让后续消息越过占位。
    public func canTransmit(_ outgoing: ChatOutgoing) throws -> Bool {
        try check()
        return try db.read { db in
            try String.fetchOne(db, sql: "SELECT message FROM delivery_order WHERE conversation=? ORDER BY position LIMIT 1", arguments: [outgoing.conversationID]) == outgoing.id.uuidString.lowercased()
        }
    }
    public func orderedMessageIDs(conversation: String) throws -> [String] {
        try check()
        return try db.read { try String.fetchAll($0, sql: "SELECT message FROM delivery_order WHERE conversation=? ORDER BY position", arguments: [conversation]) }
    }
    public func enqueue(_ outgoing: ChatOutgoing) throws {
        try check()
        let value = ChatPendingMessage(
            outgoing: outgoing, state: "waiting", createdAt: Date(), failure: nil)
        let data = try JSONEncoder().encode(value)
        try db.write { db in
            try db.execute(sql: "INSERT INTO outbox VALUES (?,?)", arguments: [outgoing.id.uuidString.lowercased(), data])
            try Self.order(outgoing.id, conversation: outgoing.conversationID, db: db)
            try Self.recordListSend(outgoing.conversationID, at: value.createdAt, db: db)
        }
    }
    public func pending() throws -> [ChatPendingMessage] {
        try check()
        return try db.read { db in
            try Data.fetchAll(db, sql: "SELECT o.payload FROM outbox o JOIN delivery_order d ON d.message=o.id ORDER BY d.position").map {
                try JSONDecoder().decode(ChatPendingMessage.self, from: $0)
            }
        }
    }
    public func update(_ pending: ChatPendingMessage) throws {
        try check()
        let data = try JSONEncoder().encode(pending)
        try db.write {
            try $0.execute(
                sql: "UPDATE outbox SET payload=? WHERE id=?",
                arguments: [data, pending.outgoing.id.uuidString.lowercased()])
        }
    }
    public func draft(_ conversation: String) throws -> ChatLocalDraft {
        try check()
        return try db.read { db in
            let conversation = try Self.canonicalDraftConversation(conversation, db: db)
            return try Data.fetchOne(
                db, sql: "SELECT payload FROM draft WHERE id=?", arguments: [conversation]
            ).map {
                try JSONDecoder().decode(ChatLocalDraft.self, from: $0)
            } ?? ChatLocalDraft()
        }
    }
    /// 在同一加密事务中保存原版草稿与旧界面的纯文本投影。
    public func saveEditorDraft<T: Encodable & Sendable>(_ snapshot: T, text: String, conversation: String,
        reediting message: String? = nil, expectedText: String? = nil) throws {
        try check()
        let bytes = try JSONEncoder().encode(snapshot)
        let draft = try JSONEncoder().encode(ChatLocalDraft(text: text))
        try db.write { db in
            let original = conversation
            let conversation = try Self.canonicalDraftConversation(original, db: db)
            let bytes = conversation == original ? bytes : try Self.rebindingEditorDraft(bytes, to: conversation)
            if let message {
                let original = try Self.reeditText(message: message, conversation: conversation, now: now(), db: db)
                guard original == expectedText else { throw ChatStoreError.draftChanged }
            }
            let previous = try Self.draftPreview(conversation, db: db)
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: ["rich-draft:" + conversation, bytes])
            try db.execute(sql: "INSERT OR REPLACE INTO draft VALUES (?,?)", arguments: [conversation, draft])
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
        }
    }
    public func saveDraft(_ draft: ChatLocalDraft, conversation: String) throws {
        try check()
        let data = try JSONEncoder().encode(draft)
        try db.write { db in
            let conversation = try Self.canonicalDraftConversation(conversation, db: db)
            let preview = try Self.draftPreview(conversation, db: db)
            let previous = try Data.fetchOne(db, sql: "SELECT payload FROM draft WHERE id=?", arguments: [conversation])
                .map { try JSONDecoder().decode(ChatLocalDraft.self, from: $0) }
            if previous?.text != draft.text {
                try db.execute(sql: "DELETE FROM meta WHERE id=?", arguments: ["rich-draft:" + conversation])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO draft VALUES (?,?)", arguments: [conversation, data])
            try Self.recordDraftChange(preview, conversation: conversation, db: db)
        }
    }
    /// 删除本地未确认消息；已发出的请求仍可能确认，hidden 记录继续隐藏相同身份。
    public func removePending(message: String) throws {
        try check()
        try db.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [message])
            try db.execute(sql: "DELETE FROM delivery_order WHERE message=?", arguments: [message])
        }
    }
    public func hide(message: String) throws {
        try check()
        try db.write { db in
            try Self.invalidateMedia(message: message, db: db)
            try db.execute(sql: "INSERT OR IGNORE INTO hidden VALUES (?)", arguments: [message])
            try db.execute(sql: "DELETE FROM message_search WHERE id=?", arguments: [message])
            try db.execute(
                sql: "UPDATE revoke_recovery SET text=NULL,runs=NULL,state='expired' WHERE id=?",
                arguments: [message])
        }
    }
    public func clear(conversation: String) throws {
        try check()
        try db.write { try Self.clearHistory(conversation, db: $0) }
    }
    static func clearHistory(_ conversation: String, db: Database) throws {
        let snapshot = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?", arguments: [conversation])
            .map { try JSONDecoder().decode(ChatConversation.self, from: $0) }
        let local = try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM entity WHERE bucket='message' AND conversation=?", arguments: [conversation]) ?? 0
        try db.execute(sql: "INSERT INTO conversation_clear VALUES (?,?) ON CONFLICT(conversation) DO UPDATE SET sequence=MAX(sequence,excluded.sequence)", arguments: [conversation, max(local, snapshot?.latest ?? 0)])
        if let data = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?", arguments: [conversation]),
           let latest = try JSONDecoder().decode(ChatConversation.self, from: data).latestMessage {
            try db.execute(sql: "INSERT OR IGNORE INTO hidden VALUES (?)", arguments: [latest.id])
        }
        try db.execute(sql: "DELETE FROM message_search WHERE id IN (SELECT id FROM entity WHERE bucket='message' AND conversation=?)", arguments: [conversation])
        for id in try String.fetchAll(db, sql: "SELECT id FROM entity WHERE bucket='message' AND conversation=?", arguments: [conversation]) {
            try Self.invalidateMedia(message: id, db: db)
        }
        try db.execute(
            sql:
                "INSERT OR IGNORE INTO hidden SELECT id FROM entity WHERE bucket='message' AND conversation=?",
            arguments: [conversation])
        try db.execute(
            sql: "UPDATE revoke_recovery SET text=NULL,runs=NULL,state='expired' WHERE conversation=?",
            arguments: [conversation])
    }
    /// 在网络调用前保存撤回身份和本人文本；重复调用不刷新保留期限。
    public func prepareRevoke(_ message: ChatMessage, operationID: UUID) throws -> ChatRevokeAttempt
    {
        try check()
        return try db.write { db in
            try Self.expireReedits(now: now(), db: db)
            guard message.senderID == userID.uuidString.lowercased() else {
                throw ChatStoreError.scopeMismatch
            }
            if let row = try Row.fetchOne(
                db, sql: "SELECT * FROM revoke_recovery WHERE id=?", arguments: [message.id])
            {
                guard row["conversation"] as String == message.conversationID,
                    let operation = UUID(uuidString: row["operation"])
                else { throw ChatStoreError.scopeMismatch }
                return ChatRevokeAttempt(
                    operationID: operation, recoveryStored: (row["text"] as String?) != nil)
            }
            guard
                let data = try Data.fetchOne(
                    db,
                    sql:
                        "SELECT payload FROM entity WHERE bucket='message' AND id=? AND id NOT IN (SELECT id FROM hidden)",
                    arguments: [message.id])
            else { throw ChatStoreError.unavailable }
            let current = try JSONDecoder().decode(ChatMessage.self, from: data)
            guard !current.revoked, current.senderID == message.senderID,
                current.conversationID == message.conversationID
            else { throw ChatStoreError.unavailable }
            let text: String? = current.kind == "text" ? current.text : nil
            try db.execute(
                sql: "INSERT INTO revoke_recovery(id,conversation,operation,state,text,expires,runs) VALUES (?,?,?,?,?,?,?)",
                arguments: [
                    current.id, current.conversationID, operationID.uuidString, "pending", text,
                    now().addingTimeInterval(180).timeIntervalSince1970,
                    text == nil ? nil : try JSONEncoder().encode(current.textRuns ?? []),
                ])
            return ChatRevokeAttempt(operationID: operationID, recoveryStored: text != nil)
        }
    }
    /// 明确失败只清除待确认副本；同步已确认的成功结果不会被迟到错误覆盖。
    public func rejectRevoke(message: String) throws {
        try check()
        try db.write {
            try $0.execute(
                sql:
                    "UPDATE revoke_recovery SET state='expired',text=NULL,runs=NULL WHERE id=? AND state='pending'",
                arguments: [message])
        }
    }
    /// 清理到期正文，保留最小操作身份以阻止旧重试延长期限。
    public func expireReedits() throws {
        try check()
        try db.write { try Self.expireReedits(now: now(), db: $0) }
    }
    /// 返回指定会话仍在三分钟有效期内的编辑入口，并先清理过期正文。
    public func reeditAvailability(conversation: String) throws -> [ChatReeditAvailability] {
        try expireReedits()
        return try db.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT id,expires FROM revoke_recovery WHERE conversation=? AND state='confirmed' AND text IS NOT NULL AND id NOT IN (SELECT id FROM hidden)",
                arguments: [conversation]
            ).map {
                ChatReeditAvailability(
                    messageID: $0["id"], expiresAt: Date(timeIntervalSince1970: $0["expires"]))
            }
        }
    }
    /// 读取本机可恢复原文；未确认、已删除、会话不匹配或到期时抛出 `reeditExpired`。
    public func reeditText(message: String, conversation: String) throws -> String {
        try expireReedits()
        return try db.read {
            try Self.reeditText(message: message, conversation: conversation, now: now(), db: $0)
        }
    }
    /// 返回仍可重新编辑的语义格式，与原文使用相同的期限和账号校验。
    public func reeditRuns(message: String, conversation: String) throws -> [ChatTextRun] {
        _ = try reeditText(message: message, conversation: conversation)
        return try db.read { db in
            try Data.fetchOne(db, sql: "SELECT runs FROM revoke_recovery WHERE id=?", arguments: [message])
                .map { try JSONDecoder().decode([ChatTextRun].self, from: $0) } ?? []
        }
    }
    /// 在同一事务中检查期限与草稿，再仅替换草稿文字；附件身份保持不变。
    public func restoreReeditedDraft(message: String, conversation: String, expectedText: String)
        throws -> ChatLocalDraft
    {
        try expireReedits()
        return try db.write { db in
            try Self.expireReedits(now: now(), db: db)
            let text = try Self.reeditText(
                message: message, conversation: conversation, now: now(), db: db)
            var draft =
                try Data.fetchOne(
                    db, sql: "SELECT payload FROM draft WHERE id=?", arguments: [conversation]
                ).map { try JSONDecoder().decode(ChatLocalDraft.self, from: $0) }
                ?? ChatLocalDraft()
            guard draft.text == expectedText else { throw ChatStoreError.draftChanged }
            let preview = try Self.draftPreview(conversation, db: db)
            draft.text = text
            try db.execute(
                sql: "INSERT OR REPLACE INTO draft VALUES (?,?)",
                arguments: [conversation, JSONEncoder().encode(draft)])
            try Self.recordDraftChange(preview, conversation: conversation, db: db)
            return draft
        }
    }
    private static func expireReedits(now: Date, db: Database) throws {
        try db.execute(
            sql:
                "UPDATE revoke_recovery SET state='expired',text=NULL,runs=NULL WHERE expires<=? AND state!='expired'",
            arguments: [now.timeIntervalSince1970])
    }
    private static func reeditText(message: String, conversation: String, now: Date, db: Database)
        throws -> String
    {
        guard
            let text = try String.fetchOne(
                db,
                sql:
                    "SELECT text FROM revoke_recovery WHERE id=? AND conversation=? AND state='confirmed' AND expires>? AND id NOT IN (SELECT id FROM hidden)",
                arguments: [message, conversation, now.timeIntervalSince1970])
        else { throw ChatStoreError.reeditExpired }
        return text
    }
    public func transfers<T: Codable & Sendable>(as type: T.Type) throws -> [T] {
        try check()
        return try db.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM transfer").map {
                try JSONDecoder().decode(T.self, from: $0)
            }
        }
    }
    public func saveTransfer<T: Codable & Sendable>(_ value: T, id: UUID) throws {
        try check()
        try db.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM transfer WHERE id=?)", arguments: [id.uuidString]) ?? false
            var data = try JSONEncoder().encode(value)
            if var batch = value as? ChatUploadBatch,
                let oldData = try Data.fetchOne(
                    db, sql: "SELECT payload FROM transfer WHERE id=?", arguments: [id.uuidString]),
                let old = try? JSONDecoder().decode(ChatUploadBatch.self, from: oldData),
                old.cancelRequested
            {
                batch.cancelRequested = true
                data = try JSONEncoder().encode(batch)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO transfer VALUES (?,?)",
                arguments: [id.uuidString, data])
            if let batch = value as? ChatUploadBatch {
                try Self.order(batch.messageID, conversation: batch.conversation, db: db)
                if !exists { try Self.recordListSend(batch.conversation, at: batch.createdAt, db: db) }
            }
        }
    }
    public func removeTransfer(_ id: UUID) throws {
        try check()
        try db.write { db in
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM transfer WHERE id=?", arguments: [id.uuidString]),
               let batch = try? JSONDecoder().decode(ChatUploadBatch.self, from: data) {
                try db.execute(sql: "DELETE FROM delivery_order WHERE message=?", arguments: [batch.messageID.uuidString.lowercased()])
            }
            try db.execute(sql: "DELETE FROM transfer WHERE id=?", arguments: [id.uuidString])
        }
    }
    /// 媒体组进入 outbox 与上传任务完成同事务提交，防止重启生成第二条消息。
    public func submitTransfer(_ outgoing: ChatOutgoing, transfer: UUID) throws {
        try check()
        let value = ChatPendingMessage(
            outgoing: outgoing, state: "waiting", createdAt: Date(), failure: nil)
        try db.write { db in
            guard
                let data = try Data.fetchOne(
                    db, sql: "SELECT payload FROM transfer WHERE id=?",
                    arguments: [transfer.uuidString])
            else { return }
            let batch = try JSONDecoder().decode(ChatUploadBatch.self, from: data)
            guard !batch.cancelRequested else { throw ChatStoreError.transferCancelled }
            guard batch.messageID == outgoing.id, batch.conversation == outgoing.conversationID
            else {
                throw ChatStoreError.scopeMismatch
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO outbox VALUES (?,?)",
                arguments: [outgoing.id.uuidString.lowercased(), JSONEncoder().encode(value)])
            try db.execute(sql: "DELETE FROM transfer WHERE id=?", arguments: [transfer.uuidString])
        }
    }
    private static func checkpoint(_ value: ChatCheckpoint, db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO meta VALUES ('checkpoint', ?)",
            arguments: [JSONEncoder().encode(value)])
    }
    /// 保存派生展示结果前重查撤回和本机删除终态，拒绝迟到的转写与媒体回调。
    public func savePresentation<T: Encodable & Sendable>(_ value: T, message: String, transcript: Bool = false) throws {
        try check()
        try db.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hidden WHERE id=?", arguments: [message]) == 0 else { throw ChatStoreError.unavailable }
            if let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND id=?", arguments: [message]),
               try JSONDecoder().decode(ChatMessage.self, from: bytes).revoked { throw ChatStoreError.unavailable }
            if !transcript, let previous = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["presentation:" + message]) {
                let old = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["presentation-resources:" + message])
                    .map { try JSONDecoder().decode([UUID].self, from: $0) } ?? []
                let ids = Set(old).union(try Self.presentationResources(previous))
                try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: ["presentation-resources:" + message, JSONEncoder().encode(Array(ids))])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: [(transcript ? "transcript:" : "presentation:") + message, JSONEncoder().encode(value)])
        }
    }
    public func mediaInvalidations() throws -> [UUID] {
        try check()
        return try db.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='media-invalidations'")
                .map { try JSONDecoder().decode([UUID].self, from: $0) } ?? []
        }
    }
    public func acknowledgeMediaInvalidations(_ ids: Set<UUID>) throws {
        try check()
        try db.write { db in
            let all = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='media-invalidations'")
                .map { try JSONDecoder().decode([UUID].self, from: $0) } ?? []
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('media-invalidations',?)", arguments: [JSONEncoder().encode(all.filter { !ids.contains($0) })])
        }
    }
    private static func invalidateMedia(message: String, resources: [String] = [], db: Database) throws {
        var ids = Set(resources.compactMap(UUID.init(uuidString:)))
        if let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["presentation:" + message]) {
            ids.formUnion(try presentationResources(bytes))
        }
        if let retired = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["presentation-resources:" + message]) {
            ids.formUnion(try JSONDecoder().decode([UUID].self, from: retired))
        }
        let existing = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='media-invalidations'")
            .map { try JSONDecoder().decode([UUID].self, from: $0) } ?? []
        ids.formUnion(existing)
        try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES ('media-invalidations',?)", arguments: [JSONEncoder().encode(Array(ids))])
        try db.execute(sql: "DELETE FROM meta WHERE id IN (?,?,?)", arguments: ["presentation:" + message, "transcript:" + message, "presentation-resources:" + message])
    }
    private static func presentationResources(_ bytes: Data) throws -> Set<UUID> {
        var ids = Set<UUID>()
        func collect(_ object: Any) {
            if let text = object as? String, let url = URL(string: text), url.scheme == "azurefish-media", let id = url.host.flatMap(UUID.init(uuidString:)) { ids.insert(id) }
            else if let values = object as? [Any] { values.forEach(collect) }
            else if let values = object as? [String: Any] { values.values.forEach(collect) }
        }
        collect(try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed))
        return ids
    }
    private static func put<T: Encodable>(
        _ value: T, bucket: String, id: String, revision: Int64, conversation: String = "",
        sequence: Int64 = 0,
        db: Database
    ) throws {
        let old =
            try Int64.fetchOne(
                db, sql: "SELECT revision FROM entity WHERE bucket=? AND id=?",
                arguments: [bucket, id])
            ?? -1
        guard revision >= old else { return }
        try db.execute(
            sql: "INSERT OR REPLACE INTO entity VALUES (?,?,?,?,?,?)",
            arguments: [bucket, id, revision, conversation, sequence, JSONEncoder().encode(value)])
    }
    private static func putContact(_ incoming: ChatContact, db: Database) throws {
        var value = incoming
        if let data = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='contact' AND id=?", arguments: [value.peer.id]) {
            value = try JSONDecoder().decode(ChatContact.self, from: data).merging(incoming)
        }
        try put(value.peer, bucket: "profile", id: value.peer.id, revision: value.peer.version, db: db)
        try put(value, bucket: "contact", id: value.peer.id, revision: value.revision, db: db)
    }
    static func putConversation(_ value: ChatConversation, userID: UUID, db: Database) throws {
        for member in value.members {
            try put(member.profile, bucket: "profile", id: member.id, revision: member.profile.version, db: db)
        }
        var value = value
        if let data = try Data.fetchOne(
            db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?",
            arguments: [value.id])
        {
            let old = try JSONDecoder().decode(ChatConversation.self, from: data)
            if old.revision > value.revision {
                let incoming = value
                value = old
                if incoming.readState.revision > value.readState.revision {
                    value.readState = incoming.readState
                    value.latest = incoming.latest
                    value.latestMessage = incoming.latestMessage
                }
            } else if old.readState.revision > value.readState.revision {
                value.readState = old.readState
                value.latest = old.latest
                value.latestMessage = old.latestMessage
            }
            if value.latestMessage == nil, value.latest == old.latest { value.latestMessage = old.latestMessage }
            if let previous = old.latestMessage, let current = value.latestMessage,
               previous.id == current.id && (previous.revision > current.revision || previous.revoked) {
                value.latestMessage = previous
            }
        }
        try put(value, bucket: "conversation", id: value.id, revision: value.revision, db: db)
        if let message = value.latestMessage {
            try recordListMessage(message, userID: userID, restoreHidden: true, db: db)
        }
    }
    private static func putMessage(_ value: ChatMessage, userID: UUID, now: Date, restoreListVisibility: Bool? = nil, db: Database)
        throws
    {
        var value = value
        let previousData = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND id=?", arguments: [value.id])
        if let data = previousData {
            let old = try JSONDecoder().decode(ChatMessage.self, from: data)
            if old.revision > value.revision || old.revoked {
                let receipt = value.receipt
                value = old
                if receipt.revision > value.receipt.revision { value.receipt = receipt }
            } else if old.receipt.revision > value.receipt.revision {
                value.receipt = old.receipt
            }
        }
        if value.revoked {
            let previous = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='message' AND id=?", arguments: [value.id])
                .map { try JSONDecoder().decode(ChatMessage.self, from: $0) }
            try invalidateMedia(message: value.id, resources: (previous?.assets ?? []).flatMap(\.resources).map(\.id), db: db)
            value.text = ""
            value.textRuns = nil
            value.linkURL = nil
            value.assets = []
        }
        try put(
            value, bucket: "message", id: value.id, revision: value.revision,
            conversation: value.conversationID,
            sequence: value.sequence, db: db)
        try recordListMessage(value, userID: userID, restoreHidden: restoreListVisibility ?? (previousData == nil), db: db)
        try expireReedits(now: now, db: db)
        if value.revoked, value.senderID == userID.uuidString.lowercased() {
            try db.execute(
                sql:
                    "UPDATE revoke_recovery SET state='confirmed',expires=? WHERE id=? AND conversation=? AND state='pending' AND text IS NOT NULL",
                arguments: [
                    now.addingTimeInterval(180).timeIntervalSince1970, value.id,
                    value.conversationID,
                ])
        }
        let cutoff = try Int64.fetchOne(db, sql: "SELECT sequence FROM conversation_clear WHERE conversation=?", arguments: [value.conversationID]) ?? 0
        if value.sequence <= cutoff {
            try db.execute(sql: "INSERT OR IGNORE INTO hidden VALUES (?)", arguments: [value.id])
        }
        try db.execute(sql: "DELETE FROM outbox WHERE id=?", arguments: [value.id])
        try db.execute(sql: "DELETE FROM delivery_order WHERE message=?", arguments: [value.id])
        try db.execute(sql: "DELETE FROM message_search WHERE id=?", arguments: [value.id])
        if !value.revoked && ["text", "link"].contains(value.kind),
           try !(Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hidden WHERE id=?)", arguments: [value.id]) ?? false) {
            try db.execute(
                sql: "INSERT INTO message_search VALUES (?,?)", arguments: [value.id, ChatSearchTokenizer.tokens(value.text).joined(separator: " ")])
        }
    }
}

/// 一次发送中按编辑器顺序排列的文字、链接或媒体上传占位。
public enum ChatCompositionItem: Sendable {
    case message(ChatOutgoing)
    case upload(ChatUploadBatch)
}
