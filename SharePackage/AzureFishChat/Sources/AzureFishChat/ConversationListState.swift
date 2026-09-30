import AzureFishAPI
import Foundation
import GRDB

/// 当前设备的会话列表状态；隐藏边界与服务端已读水位互相独立。
public struct ConversationListState: Sendable, Equatable {
    /// 会话是否曾由聊天内容、发送或草稿进入列表，默认 false。
    public var hasAppeared = false
    /// 本机隐藏会话时的序列边界；nil 表示未隐藏。
    public var hiddenThrough: Int64?
    /// 当前账号在本机是否为会话设置手动未读提醒，不修改服务端已读水位。
    public var manuallyUnread = false
    /// 最近受理发送或收到聊天内容的时间，单位为 Unix 毫秒；清空与隐藏不重置。
    public var activityAt: Int64 = 0
    /// 已完成列表检查的最新序列；-1 表示尚未检查。
    public var inspectedThrough: Int64 = -1
    /// 已完成列表检查的可见边界版本；-1 表示尚未检查。
    public var inspectedBoundary: Int64 = -1
    /// 仅当会话已出现且没有 hiddenThrough 隐藏边界时为 true。
    public var isVisible: Bool { hasAppeared && hiddenThrough == nil }
    /// 创建未出现、未隐藏、未手动标记未读且尚未检查历史的默认列表状态。
    public init() {}

    /// 从已读取的本机会话状态记录恢复列表显示字段，不访问数据库。
    init(_ row: LocalStateRecord) {
        hasAppeared = row.appeared; hiddenThrough = row.hiddenThrough; manuallyUnread = row.manuallyUnread
        activityAt = row.activityAt; inspectedThrough = row.inspectedThrough; inspectedBoundary = row.inspectedBoundary
    }
}

extension ChatStore {
    /// 读取会话本机状态；缺失时构造未出现、未隐藏且未检查的默认记录，不立即写入。
    static func localState(_ conversation: String, db: Database) throws -> LocalStateRecord {
        try LocalStateRecord.fetchOne(db, key: conversation) ?? .init(conversationID: conversation,
            appeared: false, hiddenThrough: nil, manuallyUnread: false, activityAt: 0,
            inspectedThrough: -1, inspectedBoundary: -1, clearedThrough: 0)
    }
    /// 将会话本机记录映射为列表状态快照，缺失记录按默认状态处理。
    static func listState(_ conversation: String, db: Database) throws -> ConversationListState {
        ConversationListState(try localState(conversation, db: db))
    }
    /// 保存列表字段并保留现有 clearedThrough 历史清空边界。
    static func saveListState(_ value: ConversationListState, conversation: String, db: Database) throws {
        var row = try localState(conversation, db: db)
        row.appeared = value.hasAppeared; row.hiddenThrough = value.hiddenThrough; row.manuallyUnread = value.manuallyUnread
        row.activityAt = value.activityAt; row.inspectedThrough = value.inspectedThrough; row.inspectedBoundary = value.inspectedBoundary
        try row.upsert(db)
    }

    /// 仅用当前账号可访问的非系统消息更新活动状态；是否解除隐藏由 restoreHidden 和序列共同决定。
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

    /// 记录本机受理发送的活动时间，使会话出现并解除列表隐藏。
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
            Dictionary(uniqueKeysWithValues: try LocalStateRecord.fetchAll(db).map {
                ($0.conversationID, ConversationListState($0))
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
            let latest = try ConversationRecord.fetchOne(db, key: conversation)?.latest ?? 0
            let local = try MessageRecord.filter(MessageRecord.Columns.conversationID == conversation)
                .select(max(MessageRecord.Columns.sequence), as: Int64.self).fetchOne(db) ?? 0
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
    /// 列表展示的草稿纯文本投影，保留用户文字。
    public let text: String
    /// 草稿是否含附件，不读取或解密对应文件。
    public let hasAttachments: Bool
    /// 按编辑器顺序保存的附件及媒体子项身份，用于判断摘要是否变化。
    let attachmentIdentity: [String]
    /// 文字为空且没有附件时为 true。
    public var isEmpty: Bool { text.isEmpty && !hasAttachments }
}

extension ChatStore {
    /// 读取指定会话的文字及附件身份摘要；不存在时返回空摘要。
    static func draftPreview(_ conversation: String, db: Database) throws -> ConversationDraftPreview {
        try DraftRepository.previews([conversation], in: db)[conversation]
            ?? .init(text: "", hasAttachments: false, attachmentIdentity: [])
    }

    /// 非空草稿摘要确实变化时恢复会话可见性，不改变消息活动时间。
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
            let conversation = try Self.canonicalDraftConversation(conversation, db: db)
            let previous = try Self.draftPreview(conversation, db: db)
            try DraftRepository.row(conversation, in: db).upsert(db)
            try DraftUploadRepository.saveItems(items, owner: conversation, in: db)
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
        }
    }

    /// 在同一读取事务中返回列表状态、草稿与折叠偏好，避免摘要和可见性取自不同保存时刻。
    public func conversationListSnapshot() throws -> (states: [String: ConversationListState], drafts: [String: ConversationDraftPreview], pinnedCollapsed: Bool) {
        try check()
        return try db.read { db in
            let states = Dictionary(uniqueKeysWithValues: try LocalStateRecord.fetchAll(db).map {
                ($0.conversationID, ConversationListState($0))
            })
            let drafts = try DraftRepository.previews(in: db).filter { !$0.value.isEmpty }
            let collapsed = try AccountPreferenceRecord.fetchOne(db, key: 1)?.pinnedCollapsed ?? false
            return (states, drafts, collapsed)
        }
    }

    /// 折叠仅属于当前账号本机的显示偏好，不隐藏会话或更改未读水位。
    public func setPinnedConversationsCollapsed(_ collapsed: Bool) throws {
        try check()
        try db.write { try AccountPreferenceRecord(id: 1, pinnedCollapsed: collapsed).upsert($0) }
    }
}
