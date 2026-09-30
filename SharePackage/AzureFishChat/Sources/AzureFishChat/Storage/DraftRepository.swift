import Foundation
import GRDB

/// 草稿根记录及图结构的事务映射。
enum DraftRepository {
    /// 读取草稿根记录；不存在时返回版本 1、修订 0 的空草稿，不立即保存。
    static func row(_ id: String, in db: Database) throws -> DraftRecord {
        try DraftRecord.fetchOne(db, key: id) ?? .init(conversationID: id, text: "", hasEditor: false, version: 1, revision: "0")
    }
    /// 装配指定会话的纯文字与有序资产身份草稿，缺失时返回空草稿。
    static func legacy(_ id: String, in db: Database) throws -> ChatLocalDraft {
        let text = try row(id, in: db).text
        let assets = try DraftAssetRecord.filter(DraftAssetRecord.Columns.conversationID == id).order(DraftAssetRecord.Columns.position).fetchAll(db).map(\.assetID)
        return .init(text: text, assets: assets)
    }
    /// 读取完整类型化编辑器草稿；hasEditor 为 false 时返回 nil，关联或修订损坏时抛错。
    static func editor(_ id: String, in db: Database) throws -> StoredChatDraft? {
        let row = try row(id, in: db)
        guard row.hasEditor else { return nil }
        guard var value = try DraftGraphRepository.fetch([id], in: db)[id], let revision = UInt64(row.revision) else { throw ChatStoreError.unavailable }
        value.version = row.version; value.revision = revision
        return value
    }
    /// 保存文字及有序资产身份；文字变化时失效旧编辑器结构，并登记其资源清理。
    static func saveLegacy(_ value: ChatLocalDraft, id: String, in db: Database) throws {
        var row = try row(id, in: db)
        if row.text != value.text {
            try retireEditorResources(id, keeping: [], in: db)
            row.hasEditor = false; try DraftGraphRepository.clear(id, in: db)
        }
        row.text = value.text
        try row.upsert(db)
        try DraftAssetRecord.filter(DraftAssetRecord.Columns.conversationID == id).deleteAll(db)
        for (position, asset) in value.assets.enumerated() { try DraftAssetRecord(conversationID: id, position: position, assetID: asset).insert(db) }
    }
    /// 校验版本 1 后保存编辑器根记录和完整结构；移除旧版资产身份并登记不再保留的资源。
    static func saveEditor(_ value: StoredChatDraft, text: String, in db: Database) throws {
        guard value.version == 1 else { throw ChatStoreError.incompatibleSchema }
        try retireEditorResources(value.conversationID, keeping: value.resourceIDs, in: db)
        try DraftRecord(conversationID: value.conversationID, text: text, hasEditor: true, version: value.version, revision: String(value.revision)).upsert(db)
        try DraftAssetRecord.filter(DraftAssetRecord.Columns.conversationID == value.conversationID).deleteAll(db)
        try DraftGraphRepository.save(value, owner: value.conversationID, in: db)
    }
    /// 比较原编辑器资源与 keeping 集合，将不再保留的资源登记为清理候选。
    static func retireEditorResources(_ id: String, keeping: Set<UUID>, in db: Database) throws {
        let previous = try editor(id, in: db)?.resourceIDs ?? []
        for resource in previous.subtracting(keeping) {
            try CleanupRecord(resourceID: resource.uuidString.lowercased()).upsert(db)
        }
    }
    /// 登记草稿及旧版上传附件的资源清理，删除草稿根记录和相关附件引用。
    static func remove(_ id: String, in db: Database) throws {
        try retireEditorResources(id, keeping: [], in: db)
        for resource in try DraftUploadResourceRecord.filter(DraftUploadResourceRecord.Columns.conversationID == id).fetchAll(db) {
            try CleanupRecord(resourceID: resource.resourceID.lowercased()).upsert(db)
        }
        try DraftRecord.deleteOne(db, key: id)
        try DraftUploadRepository.removeItems(id, in: db)
    }
    /// 批量装配草稿纯文字及附件身份摘要；ids 为 nil 时读取全部，不读取媒体文件。
    static func previews(_ ids: [String]? = nil, in db: Database) throws -> [String: ConversationDraftPreview] {
        let rows: [DraftRecord]
        if let ids { rows = try DraftRecord.filter(ids.contains(DraftRecord.Columns.conversationID)).fetchAll(db) }
        else { rows = try DraftRecord.fetchAll(db) }
        let editors = try DraftGraphRepository.fetch(rows.filter(\.hasEditor).map(\.conversationID), in: db)
        let owners = rows.filter { !$0.hasEditor }.map { $0.conversationID }
        let legacy = try DraftUploadRepository.items(owners, in: db)
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            var identity: [String] = [], hasAttachments = false
            if let editor = editors[row.conversationID] {
                var attachments = editor.documents
                if let media = editor.media { attachments.append(.mediaGroup(media)) }
                if let audio = editor.audio { attachments.append(.audio(audio)) }
                hasAttachments = !attachments.isEmpty
                for attachment in attachments {
                    identity.append(attachment.id.uuidString)
                    if case .mediaGroup(let group) = attachment { identity += group.items.map { $0.id.uuidString } }
                }
            } else {
                let items = legacy[row.conversationID] ?? []
                hasAttachments = !items.isEmpty
                identity = items.flatMap { [$0.id.uuidString] + $0.resources.map { $0.id.uuidString } }
            }
            return (row.conversationID, .init(text: row.text, hasAttachments: hasAttachments, attachmentIdentity: identity))
        })
    }
}
