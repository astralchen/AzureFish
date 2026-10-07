import AzureFishAPI
import Foundation
import GRDB

/// 发送身份与上传集合映射；所有方法使用调用者的事务。
enum SendRepository {
    /// 在调用者事务中保存消息任务及有序格式、资产引用；insertOnly 为 true 时冲突抛错，否则按主键插入或更新。
    static func save(_ pending: ChatPendingMessage, insertOnly: Bool = false, in db: Database) throws {
        let value = pending.outgoing, id = value.id.uuidString.lowercased()
        let row = SendTaskRecord(id: id, conversationID: value.conversationID, clientID: value.clientID.uuidString,
            operationID: value.operationID.uuidString, deviceID: value.deviceID.uuidString, kind: value.kind,
            text: value.text, linkURL: value.linkURL, hasTextRuns: value.textRuns != nil, state: pending.state,
            createdAt: pending.createdAt.timeIntervalSince1970, failure: pending.failure)
        if insertOnly { try row.insert(db) } else { try row.upsert(db) }
        try SendRunRecord.filter(SendRunRecord.Columns.messageID == id).deleteAll(db)
        try SendAssetRecord.filter(SendAssetRecord.Columns.messageID == id).deleteAll(db)
        for (position, run) in (value.textRuns ?? []).enumerated() { try SendRunRecord(messageID: id, position: position, text: run.text, style: run.style).insert(db) }
        for (position, asset) in value.assets.enumerated() { try SendAssetRecord(messageID: id, position: position, assetID: asset).insert(db) }
    }
    /// 按持久发送位置恢复消息任务及其格式、资产列表；身份 UUID 无效时抛错。
    static func pending(conversation: String? = nil, in db: Database) throws -> [ChatPendingMessage] {
        let values = try conversation.map { try SendTaskRecord.filter(SendTaskRecord.Columns.conversationID == $0).fetchAll(db) } ?? SendTaskRecord.fetchAll(db)
        let rows = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        let ids = values.map(\.id)
        let runs = Dictionary(grouping: try SendRunRecord.filter(ids.contains(SendRunRecord.Columns.messageID)).order(SendRunRecord.Columns.position).fetchAll(db), by: \.messageID)
        let assets = Dictionary(grouping: try SendAssetRecord.filter(ids.contains(SendAssetRecord.Columns.messageID)).order(SendAssetRecord.Columns.position).fetchAll(db), by: \.messageID)
        return try SendOrderRecord.filter(ids.contains(SendOrderRecord.Columns.messageID)).order(SendOrderRecord.Columns.position).fetchAll(db).compactMap { order in
            guard let row = rows[order.messageID] else { return nil }
            let outgoing = ChatOutgoing(conversationID: row.conversationID, deviceID: try storageUUID(row.deviceID), kind: row.kind,
                text: row.text, assets: (assets[row.id] ?? []).map(\.assetID), id: try storageUUID(row.id),
                clientID: try storageUUID(row.clientID), operationID: try storageUUID(row.operationID),
                textRuns: row.hasTextRuns ? (runs[row.id] ?? []).map { .init(text: $0.text, style: $0.style) } : nil, linkURL: row.linkURL)
            return .init(outgoing: outgoing, state: row.state, createdAt: Date(timeIntervalSince1970: row.createdAt), failure: row.failure)
        }
    }
    /// 替换指定上传批次的有序条目及资源引用，同时校验同身份资源的摘要和长度。
    static func saveItems(_ items: [ChatUploadItem], owner: String, in db: Database) throws {
        try removeItems(owner, in: db)
        for (position, item) in items.enumerated() {
            try UploadItemRecord(ownerID: owner, position: position, id: item.id.uuidString, kind: item.kind,
                assetID: item.assetID, completeID: item.completeID.uuidString, cancelID: item.cancelID.uuidString).insert(db)
            for (index, resource) in item.resources.enumerated() {
                let input = resource.input
                let id = resource.id.uuidString.lowercased()
                try AssetRepository.saveResource(.init(id: id, filename: input.filename, mime: input.mime,
                    bytes: input.bytes, sha256: input.sha256), in: db)
                try UploadResourceRecord(ownerID: owner, itemPosition: position, position: index, resourceID: id, role: input.role).insert(db)
            }
        }
    }
    /// 删除指定批次的上传条目与资源关联，不删除批次根记录或资源文件。
    static func removeItems(_ owner: String, in db: Database) throws {
        try UploadResourceRecord.filter(UploadResourceRecord.Columns.ownerID == owner).deleteAll(db)
        try UploadItemRecord.filter(UploadItemRecord.Columns.ownerID == owner).deleteAll(db)
    }
    /// 按批次身份批量恢复有序上传条目及资源清单；缺失必要资源或 UUID 无效时抛错。
    static func items(_ owners: [String], in db: Database) throws -> [String: [ChatUploadItem]] {
        let rows = try UploadItemRecord.filter(owners.contains(UploadItemRecord.Columns.ownerID)).order(UploadItemRecord.Columns.position).fetchAll(db)
        let resources = Dictionary(grouping: try UploadResourceRecord.filter(owners.contains(UploadResourceRecord.Columns.ownerID)).order(UploadResourceRecord.Columns.position).fetchAll(db), by: \.ownerID)
        let metadata = Dictionary(uniqueKeysWithValues: try ResourceRecord.filter(resources.values.flatMap { $0.map(\.resourceID) }.contains(ResourceRecord.Columns.id)).fetchAll(db).map { ($0.id, $0) })
        var result: [String: [ChatUploadItem]] = [:]
        for row in rows {
            let values: [ChatLocalMedia] = try (resources[row.ownerID] ?? []).filter { $0.itemPosition == row.position }.map {
                guard let resource = metadata[$0.resourceID] else { throw ChatStoreError.unavailable }
                return .init(id: try storageUUID($0.resourceID), input: .init(role: $0.role, filename: resource.filename, mime: resource.mime, bytes: resource.bytes, sha256: resource.sha256))
            }
            result[row.ownerID, default: []].append(.init(id: try storageUUID(row.id), kind: row.kind, resources: values,
                assetID: row.assetID, completeID: try storageUUID(row.completeID), cancelID: try storageUUID(row.cancelID)))
        }
        return result
    }
    /// 在调用者事务中保存上传批次及有序条目、资源引用；insertOnly 为 true 时冲突抛错，否则按主键插入或更新。
    static func save(_ batch: ChatUploadBatch, insertOnly: Bool = false, in db: Database) throws {
        let row = UploadBatchRecord(id: batch.id.uuidString, messageID: batch.messageID.uuidString,
            clientID: batch.clientID.uuidString, operationID: batch.operationID.uuidString, deviceID: batch.deviceID.uuidString,
            createdAt: batch.createdAt.timeIntervalSince1970, conversationID: batch.conversation, kind: batch.kind,
            state: batch.state, completedBytes: batch.completedBytes, cancelRequested: batch.cancelRequested)
        if insertOnly { try row.insert(db) } else { try row.upsert(db) }
        try saveItems(batch.items, owner: batch.id.uuidString, in: db)
    }
    /// 恢复非 removed、非 submitted 的上传批次及子项；结果没有排序保证。
    static func batches(conversation: String? = nil, in db: Database) throws -> [ChatUploadBatch] {
        var query = UploadBatchRecord.filter(!["removed", "submitted"].contains(UploadBatchRecord.Columns.state))
        if let conversation { query = query.filter(UploadBatchRecord.Columns.conversationID == conversation) }
        let rows = try query.fetchAll(db)
        let items = try items(rows.map(\.id), in: db)
        return try rows.map { .init(id: try storageUUID($0.id), messageID: try storageUUID($0.messageID),
            clientID: try storageUUID($0.clientID), operationID: try storageUUID($0.operationID), deviceID: try storageUUID($0.deviceID),
            createdAt: Date(timeIntervalSince1970: $0.createdAt), conversation: $0.conversationID, kind: $0.kind,
            items: items[$0.id] ?? [], state: $0.state, completedBytes: $0.completedBytes, cancelRequested: $0.cancelRequested) }
    }
    /// 删除上传批次子项并将根记录置为指定终态，默认 removed，以便拒绝迟到进度。
    static func removeBatch(_ id: UUID, terminal: String = "removed", in db: Database) throws {
        try removeItems(id.uuidString, in: db)
        try UploadBatchRecord.filter(UploadBatchRecord.Columns.id == id.uuidString).updateAll(db, UploadBatchRecord.Columns.state.set(to: terminal))
    }
}
