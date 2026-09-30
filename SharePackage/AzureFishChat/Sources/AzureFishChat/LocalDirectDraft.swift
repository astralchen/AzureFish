import AzureFishAPI
import Foundation
import GRDB

extension ChatStore {
    /// 返回本机联系人草稿身份，不作为服务端会话标识发送。
    public nonisolated static func localDirectID(peer: String) -> String { "local-direct:" + peer }
    /// 提取 local-direct: 前缀后的对方身份；没有此前缀时返回 nil，不验证身份格式。
    public nonisolated static func localDirectPeer(_ id: String) -> String? {
        id.hasPrefix("local-direct:") ? String(id.dropFirst("local-direct:".count)) : nil
    }
    /// 将本机私聊草稿身份映射至已绑定的权威会话；没有映射时保留原值。
    public func canonicalDraftConversation(_ id: String) throws -> String {
        try check(); return try db.read { try Self.canonicalDraftConversation(id, db: $0) }
    }
    /// 在同一读取快照中取得重定向、编辑器清单及旧系统编辑器附件。
    public func editorDraftState(_ id: String) throws -> (conversation: String, editor: StoredChatDraft?, legacy: ChatLocalDraft, attachments: [ChatUploadItem]) {
        try check()
        return try db.read { db in
            let id = try Self.canonicalDraftConversation(id, db: db)
            return (id, try DraftRepository.editor(id, in: db), try DraftRepository.legacy(id, in: db),
                    try DraftUploadRepository.items([id], in: db)[id] ?? [])
        }
    }
    /// 将本机私聊草稿身份映射至已绑定的权威会话；没有映射时保留原值。
    static func canonicalDraftConversation(_ id: String, db: Database) throws -> String {
        guard localDirectPeer(id) != nil else { return id }
        return try ResolutionRecord.fetchOne(db, key: id)?.conversationID ?? id
    }
    /// 读取本机私聊解析的待确认标记；没有记录时返回 false。
    public func isDirectResolutionPending(_ id: String) throws -> Bool {
        try check(); return try db.read { try ResolutionRecord.fetchOne($0, key: id)?.pending ?? false }
    }
    /// 保存本机私聊身份的解析待确认状态；传入非本机草稿身份时抛出 scopeMismatch。
    public func setDirectResolutionPending(_ pending: Bool, localID: String) throws {
        try check()
        guard Self.localDirectPeer(localID) != nil else { throw ChatStoreError.scopeMismatch }
        try db.write { db in
            var row = try ResolutionRecord.fetchOne(db, key: localID) ?? .init(localID: localID, operationID: nil, conversationID: nil, pending: false)
            row.pending = pending; try row.upsert(db)
        }
    }
    /// 读取或首次生成并保存私聊解析操作 UUID；后续重试复用，已有无效 UUID 时抛错。
    public func directResolutionOperation(_ localID: String) throws -> UUID {
        try check()
        guard Self.localDirectPeer(localID) != nil else { throw ChatStoreError.scopeMismatch }
        return try db.write { db in
            var row = try ResolutionRecord.fetchOne(db, key: localID) ?? .init(localID: localID, operationID: nil, conversationID: nil, pending: false)
            if let operation = row.operationID { return try storageUUID(operation) }
            let operation = UUID(); row.operationID = operation.uuidString; try row.upsert(db); return operation
        }
    }
    /// 权威会话、草稿转移与重定向同事务提交；双方都有非空草稿时回滚。
    public func bindLocalDirectDraft(_ localID: String, to conversation: ChatConversation) throws {
        try check()
        guard let peer = Self.localDirectPeer(localID), conversation.kind == "direct", Self.localDirectPeer(conversation.id) == nil,
              Set(conversation.members.map(\.id)) == Set([userID.uuidString.lowercased(), peer]) else { throw ChatStoreError.scopeMismatch }
        try db.write { db in
            let current = try Self.canonicalDraftConversation(localID, db: db)
            guard current == localID || current == conversation.id else { throw ChatStoreError.scopeMismatch }
            if current == conversation.id { return }
            let source = try Self.draftPreview(localID, db: db), target = try Self.draftPreview(conversation.id, db: db)
            guard source.isEmpty || target.isEmpty else { throw ChatStoreError.draftChanged }
            try Self.putConversation(conversation, userID: userID, db: db)
            if !source.isEmpty {
                try DraftRepository.saveLegacy(DraftRepository.legacy(localID, in: db), id: conversation.id, in: db)
                if var editor = try DraftRepository.editor(localID, in: db) {
                    editor.conversationID = conversation.id
                    try DraftRepository.saveEditor(editor, text: source.text, in: db)
                }
                let items = try DraftUploadRepository.items([localID], in: db)[localID] ?? []
                try DraftUploadRepository.saveItems(items, owner: conversation.id, in: db)
            }
            var row = try ResolutionRecord.fetchOne(db, key: localID) ?? .init(localID: localID, operationID: nil, conversationID: nil, pending: false)
            row.conversationID = conversation.id; row.pending = false; try row.upsert(db)
            try DraftRepository.remove(localID, in: db)
            try LocalStateRecord.deleteOne(db, key: localID)
            try Self.recordDraftChange(target, conversation: conversation.id, db: db)
        }
    }
}
