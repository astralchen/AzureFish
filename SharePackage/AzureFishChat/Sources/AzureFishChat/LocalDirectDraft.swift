import AzureFishAPI
import Foundation
import GRDB

extension ChatStore {
    /// 返回账号库内按联系人隔离的临时草稿标识；它不是服务端会话 ID。
    public nonisolated static func localDirectID(peer: String) -> String { "local-direct:" + peer }

    /// 返回临时草稿的联系人 ID；权威会话标识返回 `nil`。
    public nonisolated static func localDirectPeer(_ id: String) -> String? {
        guard id.hasPrefix("local-direct:") else { return nil }
        return String(id.dropFirst("local-direct:".count))
    }

    /// 返回草稿迁移后的权威会话标识；未迁移时返回原标识。
    public func canonicalDraftConversation(_ id: String) throws -> String {
        try check()
        return try db.read { try Self.canonicalDraftConversation(id, db: $0) }
    }

    /// 在同一读取快照中取得重定向、编辑器清单及旧版草稿，避免迁移期间读到两种身份。
    public func editorDraftState<T: Decodable & Sendable>(_ id: String, as type: T.Type) throws
        -> (conversation: String, editor: T?, legacy: ChatLocalDraft, attachments: [ChatUploadItem]) {
        try check()
        return try db.read { db in
            let id = try Self.canonicalDraftConversation(id, db: db)
            let editor = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["rich-draft:" + id])
                .map { try JSONDecoder().decode(T.self, from: $0) }
            let legacy = try Data.fetchOne(db, sql: "SELECT payload FROM draft WHERE id=?", arguments: [id])
                .map { try JSONDecoder().decode(ChatLocalDraft.self, from: $0) } ?? ChatLocalDraft()
            let attachments = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["attachments:" + id])
                .map { try JSONDecoder().decode([ChatUploadItem].self, from: $0) } ?? []
            return (id, editor, legacy, attachments)
        }
    }

    static func canonicalDraftConversation(_ id: String, db: Database) throws -> String {
        guard localDirectPeer(id) != nil else { return id }
        return try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: ["direct.binding:" + id])
            .map { try JSONDecoder().decode(String.self, from: $0) } ?? id
    }

    /// 原子取得首次发送的解析操作标识；重试和多窗口复用同一标识。
    public func directResolutionOperation(_ localID: String) throws -> UUID {
        try check()
        guard Self.localDirectPeer(localID) != nil else { throw ChatStoreError.scopeMismatch }
        return try db.write { db in
            let key = "direct.operation:" + localID
            if let bytes = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: [key]) {
                return try JSONDecoder().decode(UUID.self, from: bytes)
            }
            let operation = UUID()
            try db.execute(sql: "INSERT INTO meta VALUES (?,?)", arguments: [key, JSONEncoder().encode(operation)])
            return operation
        }
    }

    /// 在同一加密事务中保存权威私聊、迁移草稿并记录旧页面的写入重定向。
    ///
    /// 两边都有非空草稿时保留双方并抛出 `draftChanged`，不覆盖其他窗口的输入。
    public func bindLocalDirectDraft(_ localID: String, to conversation: ChatConversation) throws {
        try check()
        guard let peer = Self.localDirectPeer(localID), conversation.kind == "direct",
              Self.localDirectPeer(conversation.id) == nil,
              Set(conversation.members.map(\.id)) == Set([userID.uuidString.lowercased(), peer]) else {
            throw ChatStoreError.scopeMismatch
        }
        try db.write { db in
            let current = try Self.canonicalDraftConversation(localID, db: db)
            guard current == localID || current == conversation.id else { throw ChatStoreError.scopeMismatch }
            if current == conversation.id { return }
            let source = try Self.draftPreview(localID, db: db)
            let target = try Self.draftPreview(conversation.id, db: db)
            guard source.isEmpty || target.isEmpty else { throw ChatStoreError.draftChanged }
            try Self.putConversation(conversation, userID: userID, db: db)
            if !source.isEmpty {
                try db.execute(sql: "INSERT OR REPLACE INTO draft SELECT ?,payload FROM draft WHERE id=?", arguments: [conversation.id, localID])
                for prefix in ["rich-draft:", "attachments:"] {
                    if var bytes = try Data.fetchOne(db, sql: "SELECT payload FROM meta WHERE id=?", arguments: [prefix + localID]) {
                        if prefix == "rich-draft:" { bytes = try Self.rebindingEditorDraft(bytes, to: conversation.id) }
                        try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: [prefix + conversation.id, bytes])
                    }
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta VALUES (?,?)", arguments: ["direct.binding:" + localID, JSONEncoder().encode(conversation.id)])
            try db.execute(sql: "DELETE FROM draft WHERE id=?", arguments: [localID])
            try db.execute(sql: "DELETE FROM meta WHERE id IN (?,?,?)", arguments: ["rich-draft:" + localID, "attachments:" + localID, "direct.pending:" + localID])
            try db.execute(sql: "DELETE FROM conversation_list WHERE conversation=?", arguments: [localID])
            try Self.recordDraftChange(target, conversation: conversation.id, db: db)
        }
    }

    static func rebindingEditorDraft(_ bytes: Data, to id: String) throws -> Data {
        guard var value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw ChatStoreError.scopeMismatch }
        value["conversationID"] = id
        return try JSONSerialization.data(withJSONObject: value)
    }
}
