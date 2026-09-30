import Foundation
import GRDB

/// 汇总当前业务对加密资源的强引用；派生缓存与历史隐藏状态使用不同生命周期。
enum ResourceReferences {
    /// 汇总聊天业务当前持有的去重资源 UUID，包括可见消息、摘要、草稿、发送、上传及退役展示资源。
    static func all(in db: Database) throws -> Set<UUID> {
        let hidden = Set(try HiddenRecord.filter(HiddenRecord.Columns.hidden == true).fetchAll(db).map(\.messageID))
        let messages = Set(try MessageRecord.filter(MessageRecord.Columns.revoked == false).fetchAll(db).map(\.id)).subtracting(hidden)
        let summaries = Set(try SummaryRecord.filter(SummaryRecord.Columns.revoked == false).fetchAll(db).map(\.id)).subtracting(hidden)
        var assets = Set(try MessageAttachmentRecord.filter(messages.contains(MessageAttachmentRecord.Columns.messageID)).fetchAll(db).map(\.assetKey))
        assets.formUnion(try SummaryAttachmentRecord.filter(summaries.contains(SummaryAttachmentRecord.Columns.messageID)).fetchAll(db).map(\.assetKey))
        let pendingAssets = try SendAssetRecord.fetchAll(db).map(\.assetID)
        assets.formUnion(try AssetRecord.filter(pendingAssets.contains(AssetRecord.Columns.id)).fetchAll(db).map(\.key))
        var result = Set(try AssetResourceRecord.filter(assets.contains(AssetResourceRecord.Columns.assetKey)).fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        result.formUnion(try SendResourceRecord.fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        let drafts = try DraftRecord.filter(DraftRecord.Columns.hasEditor == true).fetchAll(db).map(\.conversationID)
        for value in try DraftGraphRepository.fetch(drafts, in: db).values { result.formUnion(value.resourceIDs) }
        let presentations = try PresentationRecord.fetchAll(db).map(\.messageID)
        for value in try PresentationGraphRepository.fetch(presentations, in: db).values { result.formUnion(value.resourceIDs) }
        result.formUnion(try RetiredResourceRecord.fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        result.formUnion(try UploadResourceRecord.fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        result.formUnion(try DraftUploadResourceRecord.fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        let draftAssets = try DraftAssetRecord.fetchAll(db).map(\.assetID)
        let draftKeys = try AssetRecord.filter(draftAssets.contains(AssetRecord.Columns.id)).fetchAll(db).map(\.key)
        result.formUnion(try AssetResourceRecord.filter(draftKeys.contains(AssetResourceRecord.Columns.assetKey)).fetchAll(db).compactMap { UUID(uuidString: $0.resourceID) })
        return result
    }
}
