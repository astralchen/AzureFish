import AzureFishAPI
import Foundation
import GRDB

/// 旧系统草稿的有序上传附件；独立于已提交上传批次。
enum DraftUploadRepository {
    /// 替换指定会话的有序上传附件，并将旧集合不再引用的资源登记为清理候选。
    static func saveItems(_ items: [ChatUploadItem], owner: String, in db: Database) throws {
        let kept = Set(items.flatMap(\.resources).map { $0.id.uuidString.lowercased() })
        for resource in try DraftUploadResourceRecord.filter(DraftUploadResourceRecord.Columns.conversationID == owner).fetchAll(db)
            where !kept.contains(resource.resourceID.lowercased()) {
            try CleanupRecord(resourceID: resource.resourceID.lowercased()).upsert(db)
        }
        try removeItems(owner, in: db)
        for (position, item) in items.enumerated() {
            try DraftUploadItemRecord(conversationID: owner, position: position, id: item.id.uuidString, kind: item.kind,
                assetID: item.assetID, completeID: item.completeID.uuidString, cancelID: item.cancelID.uuidString).insert(db)
            for (index, resource) in item.resources.enumerated() {
                let input = resource.input
                let id = resource.id.uuidString.lowercased()
                try AssetRepository.saveResource(.init(id: id, filename: input.filename, mime: input.mime,
                    bytes: input.bytes, sha256: input.sha256), in: db)
                try DraftUploadResourceRecord(conversationID: owner, itemPosition: position, position: index, resourceID: id, role: input.role).insert(db)
            }
        }
    }
    /// 删除指定会话的旧版上传附件及资源关联；不直接清理资源文件。
    static func removeItems(_ owner: String, in db: Database) throws {
        try DraftUploadResourceRecord.filter(DraftUploadResourceRecord.Columns.conversationID == owner).deleteAll(db)
        try DraftUploadItemRecord.filter(DraftUploadItemRecord.Columns.conversationID == owner).deleteAll(db)
    }
    /// 按会话身份批量恢复有序上传条目和资源元数据；必要资源或 UUID 损坏时抛错。
    static func items(_ owners: [String], in db: Database) throws -> [String: [ChatUploadItem]] {
        let rows = try DraftUploadItemRecord.filter(owners.contains(DraftUploadItemRecord.Columns.conversationID)).order(DraftUploadItemRecord.Columns.position).fetchAll(db)
        let resources = Dictionary(grouping: try DraftUploadResourceRecord.filter(owners.contains(DraftUploadResourceRecord.Columns.conversationID)).order(DraftUploadResourceRecord.Columns.position).fetchAll(db), by: \.conversationID)
        let metadata = Dictionary(uniqueKeysWithValues: try ResourceRecord.filter(resources.values.flatMap { $0.map(\.resourceID) }.contains(ResourceRecord.Columns.id)).fetchAll(db).map { ($0.id, $0) })
        var result: [String: [ChatUploadItem]] = [:]
        for row in rows {
            let values: [ChatLocalMedia] = try (resources[row.conversationID] ?? []).filter { $0.itemPosition == row.position }.map {
                guard let resource = metadata[$0.resourceID] else { throw ChatStoreError.unavailable }
                return .init(id: try storageUUID($0.resourceID), input: .init(role: $0.role, filename: resource.filename, mime: resource.mime, bytes: resource.bytes, sha256: resource.sha256))
            }
            result[row.conversationID, default: []].append(.init(id: try storageUUID(row.id), kind: row.kind, resources: values,
                assetID: row.assetID, completeID: try storageUUID(row.completeID), cancelID: try storageUUID(row.cancelID)))
        }
        return result
    }
}
