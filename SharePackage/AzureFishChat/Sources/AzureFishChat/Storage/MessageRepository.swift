import AzureFishAPI
import GRDB

/// 在同一读取快照批量装配消息内容；每页查询次数与消息条数无关。
enum MessageRepository {
    /// 执行根记录查询并批量装配消息内容、回执及有序附件，保留查询顺序；必要关联缺失时抛错。
    static func fetch(_ request: QueryInterfaceRequest<MessageRecord>, in db: Database) throws -> [ChatMessage] {
        let rows = try request.fetchAll(db), ids = rows.map(\.id)
        guard !rows.isEmpty else { return [] }
        let texts = Dictionary(uniqueKeysWithValues: try MessageTextRecord.filter(ids.contains(MessageTextRecord.Columns.messageID)).fetchAll(db).map { ($0.messageID, $0) })
        let links = Dictionary(uniqueKeysWithValues: try MessageLinkRecord.filter(ids.contains(MessageLinkRecord.Columns.messageID)).fetchAll(db).map { ($0.messageID, $0) })
        let unknown = Dictionary(uniqueKeysWithValues: try MessageUnknownRecord.filter(ids.contains(MessageUnknownRecord.Columns.messageID)).fetchAll(db).map { ($0.messageID, $0) })
        let systems = Dictionary(uniqueKeysWithValues: try MessageSystemRecord.filter(ids.contains(MessageSystemRecord.Columns.messageID)).fetchAll(db).map { ($0.messageID, $0) })
        let receipts = Dictionary(uniqueKeysWithValues: try MessageReceiptRecord.filter(ids.contains(MessageReceiptRecord.Columns.messageID)).fetchAll(db).map { ($0.messageID, $0) })
        let runs = Dictionary(grouping: try MessageRunRecord.filter(ids.contains(MessageRunRecord.Columns.messageID)).order(MessageRunRecord.Columns.position).fetchAll(db), by: \.messageID)
        let attachments = try MessageAttachmentRecord.filter(ids.contains(MessageAttachmentRecord.Columns.messageID)).order(MessageAttachmentRecord.Columns.position).fetchAll(db)
        let assets = try AssetRepository.fetch(attachments.map(\.assetKey), in: db)
        let grouped = Dictionary(grouping: attachments, by: \.messageID)
        return try rows.map { row in
            guard let receipt = receipts[row.id] else { throw ChatStoreError.unavailable }
            let text: String
            let url: String?
            if row.kind == "text", row.schemaVersion == 1 {
                guard let content = texts[row.id] else { throw ChatStoreError.unavailable }
                text = content.text; url = unknown[row.id]?.linkURL
            } else if row.kind == "link", row.schemaVersion == 1 {
                guard let content = links[row.id] else { throw ChatStoreError.unavailable }
                text = content.text; url = content.url
            } else if let content = unknown[row.id] {
                text = content.text; url = content.linkURL
            } else {
                guard row.schemaVersion == 1, ["system", "media_group", "image", "video", "audio", "file"].contains(row.kind)
                else { throw ChatStoreError.unavailable }
                text = ""; url = nil
            }
            let system = systems[row.id].map { ChatSystemEvent(kind: $0.kind, relationshipID: $0.relationshipID,
                relationshipRevision: $0.relationshipRevision, requesterID: $0.requesterID, accepterID: $0.accepterID) }
            return ChatMessage(id: row.id, conversationID: row.conversationID, clientID: row.clientID, serverID: row.serverID,
                senderID: row.senderID, deviceID: row.deviceID, sequence: row.sequence, createdAt: row.createdAt,
                revision: row.revision, kind: row.kind, schemaVersion: row.schemaVersion, text: text,
                textRuns: row.hasTextRuns ? (runs[row.id] ?? []).map { .init(text: $0.text, style: $0.style) } : nil,
                linkURL: url, revoked: row.revoked,
                receipt: .init(expected: receipt.expected, delivered: receipt.delivered, read: receipt.read, revision: receipt.revision),
                assets: try (grouped[row.id] ?? []).map { link in
                    guard let asset = assets[link.assetKey] else { throw ChatStoreError.unavailable }; return asset
                }, systemEvent: system)
        }
    }
    /// 按消息身份读取一个完整消息；没有根记录时返回 nil。
    static func one(_ id: String, in db: Database) throws -> ChatMessage? {
        try fetch(MessageRecord.filter(MessageRecord.Columns.id == id), in: db).first
    }
    /// 在调用者事务中替换消息根记录与内容子表，保留格式及附件顺序，不自行执行版本合并。
    static func save(_ value: ChatMessage, in db: Database) throws {
        try MessageRecord(id: value.id, conversationID: value.conversationID, clientID: value.clientID,
            serverID: value.serverID, senderID: value.senderID, deviceID: value.deviceID, sequence: value.sequence,
            createdAt: value.createdAt, revision: value.revision, kind: value.kind, schemaVersion: value.schemaVersion,
            revoked: value.revoked, hasTextRuns: value.textRuns != nil).upsert(db)
        try MessageTextRecord.deleteOne(db, key: value.id)
        try MessageLinkRecord.deleteOne(db, key: value.id)
        try MessageUnknownRecord.deleteOne(db, key: value.id)
        if value.kind == "text", value.schemaVersion == 1 {
            try MessageTextRecord(messageID: value.id, text: value.text).insert(db)
            if let url = value.linkURL { try MessageUnknownRecord(messageID: value.id, text: "", linkURL: url).insert(db) }
        } else if value.kind == "link", value.schemaVersion == 1 {
            try MessageLinkRecord(messageID: value.id, text: value.text, url: value.linkURL).insert(db)
        } else if !value.isKnownContent || !value.text.isEmpty || value.linkURL != nil {
            try MessageUnknownRecord(messageID: value.id, text: value.text, linkURL: value.linkURL).insert(db)
        }
        try MessageSystemRecord.deleteOne(db, key: value.id)
        if let system = value.systemEvent {
            try MessageSystemRecord(messageID: value.id, kind: system.kind, relationshipID: system.relationshipID,
                relationshipRevision: system.relationshipRevision, requesterID: system.requesterID, accepterID: system.accepterID).insert(db)
        }
        try MessageRunRecord.filter(MessageRunRecord.Columns.messageID == value.id).deleteAll(db)
        for (position, run) in (value.textRuns ?? []).enumerated() {
            try MessageRunRecord(messageID: value.id, position: position, text: run.text, style: run.style).insert(db)
        }
        let receipt = value.receipt
        try MessageReceiptRecord(messageID: value.id, expected: receipt.expected, delivered: receipt.delivered,
            read: receipt.read, revision: receipt.revision).upsert(db)
        try MessageAttachmentRecord.filter(MessageAttachmentRecord.Columns.messageID == value.id).deleteAll(db)
        for (position, asset) in value.assets.enumerated() {
            let key = try AssetRepository.save(asset, in: db)
            try MessageAttachmentRecord(messageID: value.id, position: position, assetKey: key).insert(db)
        }
    }
}
