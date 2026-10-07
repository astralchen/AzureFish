import AzureFishAPI
import Foundation
import GRDB

extension ChatStore {
    /// 仅在本机隐藏消息，同事务移除搜索和派生缓存、失效重新编辑副本并登记媒体清理。
    public func hide(message: String) throws {
        try check()
        try db.write { db in
            try Self.invalidateMedia(message: message, db: db)
            try HiddenRecord(messageID: message, hidden: true).upsert(db)
            try SearchRepository.remove(message, in: db)
            try Self.expireRecovery(message, db: db)
        }
    }
    /// 清空指定会话当前已知历史的本机显示，保留草稿、发送任务及会话偏好。
    public func clear(conversation: String) throws {
        try check(); try db.write { try Self.clearHistory(conversation, db: $0) }
    }
    /// 推进清空边界并隐藏已知历史及摘要，移除搜索内容并失效该会话重新编辑副本。
    static func clearHistory(_ conversation: String, db: Database) throws {
        let snapshot = try DirectoryRepository.conversation(conversation, in: db)
        let rows = try MessageRecord.filter(MessageRecord.Columns.conversationID == conversation).fetchAll(db)
        var state = try localState(conversation, db: db)
        state.clearedThrough = max(state.clearedThrough, max(rows.map(\.sequence).max() ?? 0, snapshot?.latest ?? 0))
        try state.upsert(db)
        var ids = Set(rows.map(\.id)); if let latest = snapshot?.latestMessage { ids.insert(latest.id) }
        for id in ids {
            try invalidateMedia(message: id, db: db)
            try HiddenRecord(messageID: id, hidden: true).upsert(db)
            try SearchRepository.remove(id, in: db)
        }
        for row in try ReeditRecord.filter(ReeditRecord.Columns.conversationID == conversation).fetchAll(db) { try expireRecovery(row.messageID, db: db) }
    }
    /// 校验当前账号发送的可用消息，保存或复用撤回身份；已知文字内容保留三分钟恢复副本。
    public func prepareRevoke(_ message: ChatMessage, operationID: UUID) throws -> ChatRevokeAttempt {
        try check()
        return try db.write { db in
            try Self.expireReedits(now: now(), db: db)
            guard message.senderID == userID.uuidString.lowercased() else { throw ChatStoreError.scopeMismatch }
            if let row = try ReeditRecord.fetchOne(db, key: message.id) {
                guard row.conversationID == message.conversationID else { throw ChatStoreError.scopeMismatch }
                return .init(operationID: try storageUUID(row.operationID), recoveryStored: row.text != nil)
            }
            guard try HiddenRecord.fetchOne(db, key: message.id)?.hidden != true,
                  let current = try MessageRepository.one(message.id, in: db), !current.revoked,
                  current.senderID == message.senderID, current.conversationID == message.conversationID else { throw ChatStoreError.unavailable }
            let text = current.kind == "text" && current.schemaVersion == 1 ? current.text : nil
            try ReeditRecord(messageID: current.id, conversationID: current.conversationID, operationID: operationID.uuidString,
                state: "pending", text: text, expires: now().addingTimeInterval(180).timeIntervalSince1970).insert(db)
            if text != nil {
                for (position, run) in (current.textRuns ?? []).enumerated() {
                    try ReeditRunRecord(messageID: current.id, position: position, text: run.text, style: run.style).insert(db)
                }
            }
            return .init(operationID: operationID, recoveryStored: text != nil)
        }
    }
    /// 将仍处于 pending 的撤回恢复副本标为过期；已确认副本不受影响。
    public func rejectRevoke(message: String) throws {
        try check()
        try db.write { db in
            if try ReeditRecord.fetchOne(db, key: message)?.state == "pending" { try Self.expireRecovery(message, db: db) }
        }
    }
    /// 清除指定消息的恢复文字和格式片段并保留 expired 身份记录。
    static func expireRecovery(_ message: String, db: Database) throws {
        if var row = try ReeditRecord.fetchOne(db, key: message) {
            row.text = nil; row.state = "expired"; try row.update(db)
        }
        try ReeditRunRecord.filter(ReeditRunRecord.Columns.messageID == message).deleteAll(db)
    }
    /// 清除已到截止时间的重新编辑正文及格式片段，保留过期状态和原操作身份。
    static func expireReedits(now: Date, db: Database) throws {
        for row in try ReeditRecord.filter(ReeditRecord.Columns.expires <= now.timeIntervalSince1970)
            .filter(ReeditRecord.Columns.state != "expired").fetchAll(db) { try expireRecovery(row.messageID, db: db) }
    }
    /// 清除已到截止时间的重新编辑正文及格式片段，保留过期状态和原操作身份。
    ///
    /// - Returns: 实际清除副本的会话身份；没有过期副本时为空。
    @discardableResult
    public func expireReedits() throws -> Set<String> {
        try check()
        return try db.write { db in
            let rows = try ReeditRecord.filter(ReeditRecord.Columns.expires <= now().timeIntervalSince1970)
                .filter(ReeditRecord.Columns.state != "expired").fetchAll(db)
            for row in rows { try Self.expireRecovery(row.messageID, db: db) }
            return Set(rows.map(\.conversationID))
        }
    }
    /// 先清理过期副本，再返回指定会话已确认、未隐藏且含文字的重新编辑入口；不保证排序。
    public func reeditAvailability(conversation: String) throws -> [ChatReeditAvailability] {
        try expireReedits()
        return try db.read { db in
            try ReeditRecord.filter(ReeditRecord.Columns.conversationID == conversation)
                .filter(ReeditRecord.Columns.state == "confirmed").filter(ReeditRecord.Columns.text != nil)
                .filter(!HiddenRecord.filter(HiddenRecord.Columns.hidden == true).select(HiddenRecord.Columns.messageID).contains(ReeditRecord.Columns.messageID))
                .fetchAll(db).map { .init(messageID: $0.messageID, expiresAt: Date(timeIntervalSince1970: $0.expires)) }
        }
    }
    /// 读取仍有效且已确认撤回的恢复文字；不匹配会话、过期、隐藏或缺少文字时抛出 reeditExpired。
    static func reeditText(message: String, conversation: String, now: Date, db: Database) throws -> String {
        guard let row = try ReeditRecord.fetchOne(db, key: message), row.conversationID == conversation,
              row.state == "confirmed", row.expires > now.timeIntervalSince1970, let text = row.text,
              try HiddenRecord.fetchOne(db, key: message)?.hidden != true else { throw ChatStoreError.reeditExpired }
        return text
    }
    /// 读取仍有效且已确认撤回的恢复文字；不匹配会话、过期、隐藏或缺少文字时抛出 reeditExpired。
    public func reeditText(message: String, conversation: String) throws -> String {
        try expireReedits(); return try db.read { try Self.reeditText(message: message, conversation: conversation, now: now(), db: $0) }
    }
    /// 验证重新编辑权限后按原始顺序读取格式片段；没有片段时返回空数组。
    public func reeditRuns(message: String, conversation: String) throws -> [ChatTextRun] {
        try expireReedits()
        return try db.read { db in
            _ = try Self.reeditText(message: message, conversation: conversation, now: now(), db: db)
            return try ReeditRunRecord.filter(ReeditRunRecord.Columns.messageID == message).order(ReeditRunRecord.Columns.position).fetchAll(db).map { .init(text: $0.text, style: $0.style) }
        }
    }
    /// 在同一事务中校验当前草稿文字仍等于 expectedText，再以撤回文字替换，保留旧版资产列表。
    public func restoreReeditedDraft(message: String, conversation: String, expectedText: String) throws -> ChatLocalDraft {
        try check()
        return try db.write { db in
            try Self.expireReedits(now: now(), db: db)
            let text = try Self.reeditText(message: message, conversation: conversation, now: now(), db: db)
            var value = try DraftRepository.legacy(conversation, in: db)
            guard value.text == expectedText else { throw ChatStoreError.draftChanged }
            let previous = try Self.draftPreview(conversation, db: db)
            value.text = text
            try DraftRepository.saveLegacy(value, id: conversation, in: db)
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
            return value
        }
    }
}
