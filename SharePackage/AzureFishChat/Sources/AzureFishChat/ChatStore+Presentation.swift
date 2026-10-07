import Foundation
import GRDB

extension ChatStore {
    /// 读取消息的结构化派生展示快照；没有记录或版本计数无法解析时返回 nil。
    public func presentation(message: String) throws -> StoredChatDraft? {
        try check()
        return try db.read { db in
            guard let row = try PresentationRecord.fetchOne(db, key: message),
                  var value = try PresentationGraphRepository.fetch([message], in: db)[message],
                  let revision = UInt64(row.revision) else { return nil }
            value.conversationID = row.conversationID; value.version = row.version; value.revision = revision
            return value
        }
    }
    /// 保存类型化派生展示前重查消息终态；旧版本资源保留到消息失效时清理。
    public func savePresentation(_ value: StoredChatDraft, message: String, completingImport batch: UUID? = nil) throws {
        try check()
        guard value.version == 1 else { throw ChatStoreError.incompatibleSchema }
        try db.write { db in
            try Self.checkPresentation(message, db: db)
            if let previous = try PresentationGraphRepository.fetch([message], in: db)[message] {
                for id in previous.resourceIDs { try RetiredResourceRecord(messageID: message, resourceID: id.uuidString.lowercased()).upsert(db) }
            }
            try PresentationRecord(messageID: message, conversationID: value.conversationID, version: value.version, revision: String(value.revision)).upsert(db)
            try PresentationGraphRepository.save(value, owner: message, in: db)
            try Self.completeMediaImport(batch, db: db)
        }
    }
    /// 读取消息已保存的转写文字；没有转写记录时返回 nil。
    public func transcript(message: String) throws -> String? {
        try check(); return try db.read { try TranscriptRecord.fetchOne($0, key: message)?.text }
    }
    /// 重查消息未隐藏或撤回后保存转写文字，防止迟到回调恢复已失效缓存。
    public func saveTranscript(_ text: String, message: String) throws {
        try check()
        try db.write { db in
            try Self.checkPresentation(message, db: db)
            try TranscriptRecord(messageID: message, text: text).upsert(db)
        }
    }
    /// 拒绝已隐藏或在消息、摘要表中标记撤回的消息；不要求消息记录一定存在。
    static func checkPresentation(_ message: String, db: Database) throws {
        guard try HiddenRecord.fetchOne(db, key: message)?.hidden != true,
              try MessageRecord.fetchOne(db, key: message)?.revoked != true,
              try SummaryRecord.fetchOne(db, key: message)?.revoked != true else { throw ChatStoreError.unavailable }
    }
    /// 登记消息相关资源的清理候选，并删除派生展示、转写和退役资源引用；不直接删除文件。
    static func invalidateMedia(message: String, resources: [String] = [], db: Database) throws {
        var ids = Set(resources.compactMap(UUID.init(uuidString:)))
        if let old = try MessageRepository.one(message, in: db) { ids.formUnion(old.assets.flatMap(\.resources).compactMap { UUID(uuidString: $0.id) }) }
        if let summary = try SummaryRepository.one(message, in: db) { ids.formUnion(summary.assets.flatMap(\.resources).compactMap { UUID(uuidString: $0.id) }) }
        if let previous = try PresentationGraphRepository.fetch([message], in: db)[message] { ids.formUnion(previous.resourceIDs) }
        ids.formUnion(try RetiredResourceRecord.filter(RetiredResourceRecord.Columns.messageID == message).fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        for id in ids { try CleanupRecord(resourceID: id.uuidString.lowercased()).upsert(db) }
        try PresentationRecord.deleteOne(db, key: message)
        try TranscriptRecord.deleteOne(db, key: message)
        try RetiredResourceRecord.filter(RetiredResourceRecord.Columns.messageID == message).deleteAll(db)
    }
    /// 返回聊天业务内已无引用的清理候选；仍被草稿或其他消息引用时继续保留。
    ///
    /// 此读取只检查聊天域，不保证其他业务已释放引用。实际删除应使用 cleanupMedia，
    /// 由账号数据库在排他区间内重新查询所有已注册业务。
    public func mediaInvalidations() throws -> [UUID] {
        try check()
        return try db.read { db in
            let referenced = try ResourceReferences.all(in: db)
            return try CleanupRecord.fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) }.filter { !referenced.contains($0) }
        }
    }
    /// 清理失败或仍被引用时保留请求，下次重试；成功后才确认清理。
    public func cleanupMedia(using media: ChatMediaStore) async throws {
        try check()
        let ids = try db.read { try CleanupRecord.fetchAll($0).map { try storageUUID($0.resourceID) } }
        for id in ids {
            if try await media.removeIfUnreferenced(id, database: db) {
                _ = try db.write { try CleanupRecord.deleteOne($0, key: id.uuidString.lowercased()) }
            }
        }
    }
    /// 将资源身份集合登记为清理请求；重复身份合并，不在此时删除资源文件。
    public func requestMediaCleanup(_ ids: Set<UUID>) throws {
        try check()
        try db.write { db in
            for id in ids { try CleanupRecord(resourceID: id.uuidString.lowercased()).upsert(db) }
        }
    }
    /// 删除指定资源的清理请求；调用方应在文件清理成功后确认，本方法不检查文件。
    public func acknowledgeMediaInvalidations(_ ids: Set<UUID>) throws {
        try check()
        try db.write { db in
            for id in ids { try CleanupRecord.deleteOne(db, key: id.uuidString.lowercased()) }
        }
    }
}
