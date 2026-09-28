import AzureFishAPI
import Foundation
import GRDB

/// 当前设备的会话列表状态；隐藏边界与服务端已读水位互相独立。
public struct ConversationListState: Sendable, Equatable {
    public var hasAppeared = false
    public var hiddenThrough: Int64?
    public var manuallyUnread = false
    /// 最近受理发送或收到聊天内容的时间，单位为 Unix 毫秒；清空与隐藏不重置。
    public var activityAt: Int64 = 0
    public var inspectedThrough: Int64 = -1
    public var inspectedBoundary: Int64 = -1
    public var isVisible: Bool { hasAppeared && hiddenThrough == nil }
    public init() {}

    init(_ row: Row) {
        hasAppeared = row["appeared"]
        hiddenThrough = row["hidden_through"]
        manuallyUnread = row["manual_unread"]
        activityAt = row["activity_at"]
        inspectedThrough = row["inspected_through"]
        inspectedBoundary = row["inspected_boundary"]
    }
}

extension ChatStore {
    static func migrateConversationList(_ db: Database, userID: UUID) throws {
        try db.execute(sql: """
            CREATE TABLE conversation_list (
                conversation TEXT PRIMARY KEY, appeared BOOLEAN NOT NULL DEFAULT 0,
                hidden_through INTEGER, manual_unread BOOLEAN NOT NULL DEFAULT 0,
                activity_at INTEGER NOT NULL DEFAULT 0, inspected_through INTEGER NOT NULL DEFAULT -1,
                inspected_boundary INTEGER NOT NULL DEFAULT -1)
            """)
        for bytes in try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='conversation'") {
            let conversation = try JSONDecoder().decode(ChatConversation.self, from: bytes)
            if let message = conversation.latestMessage {
                try recordListMessage(message, userID: userID, restoreHidden: false, db: db)
            }
        }
        for bytes in try Data.fetchAll(db, sql: "SELECT payload FROM entity WHERE bucket='message'") {
            try recordListMessage(JSONDecoder().decode(ChatMessage.self, from: bytes), userID: userID, restoreHidden: false, db: db)
        }
        for id in try String.fetchAll(db, sql: "SELECT conversation FROM conversation_clear WHERE sequence>0") {
            var value = try listState(id, db: db)
            value.hasAppeared = true
            try saveListState(value, conversation: id, db: db)
        }
        for bytes in try Data.fetchAll(db, sql: "SELECT payload FROM outbox") {
            let pending = try JSONDecoder().decode(ChatPendingMessage.self, from: bytes)
            try recordListSend(pending.outgoing.conversationID, at: pending.createdAt, db: db)
        }
        for bytes in try Data.fetchAll(db, sql: "SELECT payload FROM transfer") {
            let batch = try JSONDecoder().decode(ChatUploadBatch.self, from: bytes)
            try recordListSend(batch.conversation, at: batch.createdAt, db: db)
        }
    }

    static func listState(_ conversation: String, db: Database) throws -> ConversationListState {
        try Row.fetchOne(db, sql: "SELECT * FROM conversation_list WHERE conversation=?", arguments: [conversation])
            .map(ConversationListState.init) ?? .init()
    }

    static func saveListState(_ value: ConversationListState, conversation: String, db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO conversation_list VALUES (?,?,?,?,?,?,?)", arguments: [
            conversation, value.hasAppeared, value.hiddenThrough, value.manuallyUnread, value.activityAt,
            value.inspectedThrough, value.inspectedBoundary
        ])
    }

    static func recordListMessage(_ message: ChatMessage, userID: UUID, restoreHidden: Bool, db: Database) throws {
        guard message.kind != "system", try isAccessible(message, userID: userID, db: db, includingRevoked: true) else { return }
        var value = try listState(message.conversationID, db: db)
        value.hasAppeared = true
        // 历史分页可证明会话曾有内容，但不能解除用户隐藏；撤回与回执也不恢复隐藏。
        if restoreHidden, !message.revoked, let boundary = value.hiddenThrough, message.sequence > boundary {
            value.hiddenThrough = nil
        }
        value.activityAt = max(value.activityAt, message.createdAt)
        try saveListState(value, conversation: message.conversationID, db: db)
    }

    static func recordListSend(_ conversation: String, at date: Date, db: Database) throws {
        var value = try listState(conversation, db: db)
        value.hasAppeared = true
        value.hiddenThrough = nil
        value.activityAt = max(value.activityAt, Int64(date.timeIntervalSince1970 * 1000))
        try saveListState(value, conversation: conversation, db: db)
    }

    /// 返回账号库中的全部列表状态；缺少记录的会话默认不显示。
    public func conversationListStates() throws -> [String: ConversationListState] {
        try check()
        return try db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM conversation_list").map {
                ($0["conversation"] as String, ConversationListState($0))
            })
        }
    }

    /// 设置本机未读提醒，不修改服务端水位，也不使隐藏会话重新显示。
    public func setManuallyUnread(_ enabled: Bool, conversation: String) throws {
        try check()
        try db.write { db in
            var value = try Self.listState(conversation, db: db)
            value.manuallyUnread = enabled && value.isVisible
            try Self.saveListState(value, conversation: conversation, db: db)
        }
    }

    /// 隐藏会话并清除手动提醒；删除时在同一事务清空历史，保留草稿、待发送任务及设置。
    public func hideConversation(_ conversation: String, clearHistory: Bool = false) throws {
        try check()
        try db.write { db in
            let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM entity WHERE bucket='conversation' AND id=?", arguments: [conversation])
            let latest = try bytes.map { try JSONDecoder().decode(ChatConversation.self, from: $0).latest } ?? 0
            let local = try Int64.fetchOne(db, sql: "SELECT MAX(sequence) FROM entity WHERE bucket='message' AND conversation=?", arguments: [conversation]) ?? 0
            if clearHistory { try Self.clearHistory(conversation, db: db) }
            var value = try Self.listState(conversation, db: db)
            value.hiddenThrough = max(value.hiddenThrough ?? 0, max(latest, local))
            value.manuallyUnread = false
            try Self.saveListState(value, conversation: conversation, db: db)
        }
    }

    /// 保存已检查的历史边界，避免只有系统提示的会话每次同步都重新扫描。
    func finishListInspection(_ conversation: ChatConversation) throws {
        try check()
        try db.write { db in
            var value = try Self.listState(conversation.id, db: db)
            value.inspectedThrough = conversation.latest
            value.inspectedBoundary = conversation.boundaryRevision
            try Self.saveListState(value, conversation: conversation.id, db: db)
        }
    }
}

/// 会话列表的草稿摘要；资源仅包含稳定身份，不读取或解密媒体文件。
public struct ConversationDraftPreview: Sendable, Equatable {
    public let text: String
    public let hasAttachments: Bool
    let attachmentIdentity: [String]
    public var isEmpty: Bool { text.isEmpty && !hasAttachments }
}

extension ChatStore {
    // rich-draft 的 v1 清单保留 segments/documents/media/audio；兼容旧库，不在读取时改写可见性。
    static func draftPreview(_ conversation: String, db: Database) throws -> ConversationDraftPreview {
        try draftPreview(
            text: Data.fetchOne(db, sql: "SELECT payload FROM draft WHERE id=?", arguments: [conversation]),
            rich: Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["rich-draft:" + conversation]),
            attachments: Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["attachments:" + conversation]))
    }

    private static func draftPreview(text: Data?, rich: Data?, attachments: Data?) throws -> ConversationDraftPreview {
        let text = try text.map { try JSONDecoder().decode(ChatLocalDraft.self, from: $0).text } ?? ""
        var resources: [Any] = []
        if let rich, let snapshot = try JSONSerialization.jsonObject(with: rich) as? [String: Any] {
            resources += snapshot["documents"] as? [Any] ?? []
            for key in ["media", "audio"] {
                if let value = snapshot[key], !(value is NSNull) { resources.append(value) }
            }
        } else if let attachments {
            resources = try JSONSerialization.jsonObject(with: attachments) as? [Any] ?? []
        }
        func identities(_ value: Any) -> [String] {
            if let object = value as? [String: Any] {
                return object.keys.sorted().flatMap { key in
                    let value = object[key]!
                    return key == "id" ? (value as? String).map { [$0] } ?? [] : identities(value)
                }
            }
            return (value as? [Any])?.flatMap(identities) ?? []
        }
        return .init(text: text, hasAttachments: !resources.isEmpty,
                     attachmentIdentity: resources.flatMap(identities))
    }

    static func recordDraftChange(_ previous: ConversationDraftPreview, conversation: String, db: Database) throws {
        let next = try draftPreview(conversation, db: db)
        guard !next.isEmpty, next != previous else { return }
        var state = try listState(conversation, db: db)
        state.hasAppeared = true
        state.hiddenThrough = nil
        // 草稿影响摘要及可见性，不冒充已发送消息，也不改变消息活动时间。
        try saveListState(state, conversation: conversation, db: db)
    }

    /// 原子保存旧系统编辑器的附件；重复保存与资源路径变化不会恢复隐藏会话。
    public func saveDraftAttachments(_ items: [ChatUploadItem], conversation: String) throws {
        try check()
        try db.write { db in
            let previous = try Self.draftPreview(conversation, db: db)
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)",
                           arguments: ["attachments:" + conversation, JSONEncoder().encode(items)])
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
        }
    }

    /// 在同一读取事务中返回列表状态、草稿与折叠偏好，避免摘要和可见性取自不同保存时刻。
    public func conversationListSnapshot() throws -> (states: [String: ConversationListState], drafts: [String: ConversationDraftPreview], pinnedCollapsed: Bool) {
        try check()
        return try db.read { db in
            let states = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM conversation_list").map {
                ($0["conversation"] as String, ConversationListState($0))
            })
            // 批量取已有草稿，避免每次输入或同步时按所有会话逐一查询。
            let text = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,payload FROM draft").map {
                ($0["id"] as String, $0["payload"] as Data)
            })
            let metadata = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db,
                sql: "SELECT id,payload FROM meta WHERE id LIKE 'rich-draft:%' OR id LIKE 'attachments:%'").map {
                ($0["id"] as String, $0["payload"] as Data)
            })
            let ids = Set(text.keys).union(metadata.keys.map { String($0.dropFirst($0.hasPrefix("rich-draft:") ? 11 : 12)) })
            var drafts: [String: ConversationDraftPreview] = [:]
            for id in ids {
                let value = try Self.draftPreview(text: text[id], rich: metadata["rich-draft:" + id], attachments: metadata["attachments:" + id])
                if !value.isEmpty { drafts[id] = value }
            }
            let collapsed = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id='list-pinned-collapsed'")
                .map { try JSONDecoder().decode(Bool.self, from: $0) } ?? false
            return (states, drafts, collapsed)
        }
    }

    /// 折叠仅属于当前账号本机的显示偏好，不隐藏会话或更改未读水位。
    public func setPinnedConversationsCollapsed(_ collapsed: Bool) throws {
        try setMeta(collapsed, id: "list-pinned-collapsed")
    }
}
