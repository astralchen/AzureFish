import AzureFishAPI
import Foundation
import GRDB

extension ChatStore {
    /// 先排列可选文字消息，再排列上传批次，统一事务入队；全部为空时抛出 unavailable。
    public func enqueueComposition(text: ChatOutgoing?, batches: [ChatUploadBatch], conversation: String) throws {
        try enqueueComposition((text.map { [.message($0)] } ?? []) + batches.map(ChatCompositionItem.upload), conversation: conversation)
    }
    /// 按编辑器顺序入队；全部成功后才消费草稿及附件。
    public func enqueueComposition(_ items: [ChatCompositionItem], conversation: String,
                                   presentations: [String: StoredChatDraft] = [:], completingImport batch: UUID? = nil) throws {
        try check()
        guard !items.isEmpty else { throw ChatStoreError.unavailable }
        try db.write { db in
            for item in items {
                switch item {
                case .message(let value):
                    guard value.conversationID == conversation else { throw ChatStoreError.scopeMismatch }
                    try SendRepository.save(.init(outgoing: value, state: "waiting", createdAt: now(), failure: nil), insertOnly: true, in: db)
                    try Self.order(value.id, conversation: conversation, db: db)
                case .upload(let value):
                    guard value.conversation == conversation else { throw ChatStoreError.scopeMismatch }
                    try SendRepository.save(value, insertOnly: true, in: db)
                    try Self.order(value.messageID, conversation: conversation, db: db)
                }
            }
            try Self.recordListSend(conversation, at: now(), db: db)
            try DraftRepository.remove(conversation, in: db)
            for (message, value) in presentations {
                guard value.version == 1, value.conversationID == conversation else { throw ChatStoreError.scopeMismatch }
                try Self.checkPresentation(message, db: db)
                try PresentationRecord(messageID: message, conversationID: conversation, version: value.version, revision: String(value.revision)).upsert(db)
                try PresentationGraphRepository.save(value, owner: message, in: db)
            }
            try Self.completeMediaImport(batch, db: db)
        }
    }
    /// 为消息登记会话内发送顺序；已有相同会话登记时不重复插入，跨会话身份冲突时抛错。
    static func order(_ id: UUID, conversation: String, db: Database) throws {
        let id = id.uuidString.lowercased()
        if let old = try SendOrderRecord.filter(SendOrderRecord.Columns.messageID == id).fetchOne(db) {
            guard old.conversationID == conversation else { throw ChatStoreError.scopeMismatch }; return
        }
        try SendOrderRecord(position: nil, messageID: id, conversationID: conversation).insert(db)
    }
    /// 判断消息是否位于该会话的持久发送队首；没有顺序记录时返回 false。
    public func canTransmit(_ outgoing: ChatOutgoing) throws -> Bool {
        try check()
        return try db.read { try SendOrderRecord.filter(SendOrderRecord.Columns.conversationID == outgoing.conversationID)
            .order(SendOrderRecord.Columns.position).fetchOne($0)?.messageID == outgoing.id.uuidString.lowercased() }
    }
    /// 按持久发送位置返回指定会话的消息身份，包含尚未上传完成的占位。
    public func orderedMessageIDs(conversation: String) throws -> [String] {
        try check()
        return try db.read { try SendOrderRecord.filter(SendOrderRecord.Columns.conversationID == conversation)
            .order(SendOrderRecord.Columns.position).fetchAll($0).map(\.messageID) }
    }
    /// 在事务中新增 waiting 发送任务和顺序记录，并恢复会话列表可见性。
    public func enqueue(_ outgoing: ChatOutgoing) throws {
        try check()
        try db.write { db in
            let value = ChatPendingMessage(outgoing: outgoing, state: "waiting", createdAt: now(), failure: nil)
            try SendRepository.save(value, insertOnly: true, in: db)
            try Self.order(outgoing.id, conversation: outgoing.conversationID, db: db)
            try Self.recordListSend(outgoing.conversationID, at: value.createdAt, db: db)
        }
    }
    /// 按持久发送顺序恢复消息任务；上传占位本身不作为消息任务返回。
    public func pending(conversation: String? = nil) throws -> [ChatPendingMessage] {
        try check(); return try db.read { try SendRepository.pending(conversation: conversation, in: $0) }
    }
    /// 只更新仍存在的发送任务状态及失败码；身份不一致时抛错，已被移除时忽略迟到结果。
    public func update(_ value: ChatPendingMessage) throws {
        try check()
        try db.write { db in
            guard let old = try SendTaskRecord.fetchOne(db, key: value.outgoing.id.uuidString.lowercased()) else { return }
            // 任务状态可以变化，发送身份不能被重试回调替换。
            guard old.conversationID == value.outgoing.conversationID, old.operationID == value.outgoing.operationID.uuidString,
                  old.clientID == value.outgoing.clientID.uuidString, old.deviceID == value.outgoing.deviceID.uuidString else { throw ChatStoreError.scopeMismatch }
            try SendTaskRecord.filter(SendTaskRecord.Columns.id == old.id).updateAll(db,
                SendTaskRecord.Columns.state.set(to: value.state), SendTaskRecord.Columns.failure.set(to: value.failure))
        }
    }
    /// 移除消息发送任务及顺序记录，同时将其本机资源登记为清理候选。
    public func removePending(message: String) throws {
        try check()
        try db.write { db in
            try Self.retireSendResources(message, db: db)
            try SendTaskRecord.deleteOne(db, key: message)
            try SendOrderRecord.filter(SendOrderRecord.Columns.messageID == message).deleteAll(db)
        }
    }
    /// 将指定消息的发送资源引用登记为待清理项；不在事务中直接删除文件。
    static func retireSendResources(_ message: String, db: Database) throws {
        for resource in try SendResourceRecord.filter(SendResourceRecord.Columns.messageID == message).fetchAll(db) {
            try CleanupRecord(resourceID: resource.resourceID.lowercased()).upsert(db)
        }
    }
    /// 读取尚未 removed 或 submitted 的上传批次及条目；结果未按创建时间排序。
    public func transfers(conversation: String? = nil) throws -> [ChatUploadBatch] {
        try check(); return try db.read { try SendRepository.batches(conversation: conversation, in: $0) }
    }
    /// 保存上传批次；取消终态优先于迟到的进度回调。
    public func saveTransfer(_ value: ChatUploadBatch) throws {
        try check()
        try db.write { db in
            let old = try UploadBatchRecord.fetchOne(db, key: value.id.uuidString)
            var value = value
            if let old {
                if ["removed", "submitted"].contains(old.state) { return }
                guard old.messageID == value.messageID.uuidString, old.conversationID == value.conversation,
                      old.operationID == value.operationID.uuidString, old.clientID == value.clientID.uuidString,
                      old.deviceID == value.deviceID.uuidString else { throw ChatStoreError.scopeMismatch }
                let previous = try SendRepository.items([old.id], in: db)[old.id] ?? []
                guard previous.count == value.items.count else { throw ChatStoreError.scopeMismatch }
                for (before, after) in zip(previous, value.items) {
                    guard before.id == after.id, before.completeID == after.completeID, before.cancelID == after.cancelID,
                          before.kind == after.kind, before.assetID == nil || before.assetID == after.assetID,
                          before.resources.map(\.id) == after.resources.map(\.id) else { throw ChatStoreError.scopeMismatch }
                }
                value.cancelRequested = value.cancelRequested || old.cancelRequested
            }
            try SendRepository.save(value, in: db)
            try Self.order(value.messageID, conversation: value.conversation, db: db)
            if old == nil { try Self.recordListSend(value.conversation, at: value.createdAt, db: db) }
        }
    }
    /// 移除批次的发送占位和条目并记录 removed 终态，将所引用资源登记为清理候选。
    public func removeTransfer(_ id: UUID) throws {
        try check()
        try db.write { db in
            if let old = try UploadBatchRecord.fetchOne(db, key: id.uuidString) {
                try SendOrderRecord.filter(SendOrderRecord.Columns.messageID == old.messageID.lowercased()).deleteAll(db)
            }
            for resource in try UploadResourceRecord.filter(UploadResourceRecord.Columns.ownerID == id.uuidString).fetchAll(db) {
                try CleanupRecord(resourceID: resource.resourceID.lowercased()).upsert(db)
            }
            try SendRepository.removeBatch(id, in: db)
        }
    }
    /// 上传批次完成与发送任务创建同事务提交，不改变原有发送顺序。
    public func submitTransfer(_ outgoing: ChatOutgoing, transfer: UUID) throws {
        try check()
        try db.write { db in
            guard let batch = try UploadBatchRecord.fetchOne(db, key: transfer.uuidString) else { return }
            guard !["removed", "submitted"].contains(batch.state) else { return }
            guard !batch.cancelRequested else { throw ChatStoreError.transferCancelled }
            guard batch.messageID == outgoing.id.uuidString, batch.conversationID == outgoing.conversationID,
                  batch.clientID == outgoing.clientID.uuidString, batch.operationID == outgoing.operationID.uuidString,
                  batch.deviceID == outgoing.deviceID.uuidString else { throw ChatStoreError.scopeMismatch }
            if try SendTaskRecord.fetchOne(db, key: outgoing.id.uuidString.lowercased()) == nil {
                try SendRepository.save(.init(outgoing: outgoing, state: "waiting", createdAt: now(), failure: nil), insertOnly: true, in: db)
            }
            let resources = try UploadResourceRecord.filter(UploadResourceRecord.Columns.ownerID == transfer.uuidString)
                .order(UploadResourceRecord.Columns.itemPosition, UploadResourceRecord.Columns.position).fetchAll(db)
            for (position, resource) in resources.enumerated() {
                try SendResourceRecord(messageID: outgoing.id.uuidString.lowercased(), position: position, resourceID: resource.resourceID).upsert(db)
            }
            try SendRepository.removeBatch(transfer, terminal: "submitted", in: db)
        }
    }
}
