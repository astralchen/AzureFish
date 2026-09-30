import AzureFishAPI
import Foundation
import GRDB

extension ChatStore {
    /// 解析本机私聊重定向后读取文字及资产草稿；不存在时返回空草稿。
    public func draft(_ conversation: String) throws -> ChatLocalDraft {
        try check()
        return try db.read { try DraftRepository.legacy(Self.canonicalDraftConversation(conversation, db: $0), in: $0) }
    }
    /// 保存类型化编辑器快照及纯文本投影；迟到页面写入重定向到权威会话。
    public func saveEditorDraft(_ snapshot: StoredChatDraft, text: String, conversation: String,
                                reediting message: String? = nil, expectedText: String? = nil) throws {
        try check()
        guard snapshot.conversationID == conversation else { throw ChatStoreError.scopeMismatch }
        try db.write { db in
            let conversation = try Self.canonicalDraftConversation(conversation, db: db)
            if let message {
                guard try Self.reeditText(message: message, conversation: conversation, now: now(), db: db) == expectedText else { throw ChatStoreError.draftChanged }
            }
            let previous = try Self.draftPreview(conversation, db: db)
            var value = snapshot; value.conversationID = conversation
            try DraftRepository.saveEditor(value, text: text, in: db)
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
        }
    }
    /// 事务保存文字和资产草稿并更新列表可见性；文字改变时清理旧编辑器结构及其资源引用。
    public func saveDraft(_ value: ChatLocalDraft, conversation: String) throws {
        try check()
        try db.write { db in
            let conversation = try Self.canonicalDraftConversation(conversation, db: db)
            let previous = try Self.draftPreview(conversation, db: db)
            try DraftRepository.saveLegacy(value, id: conversation, in: db)
            try Self.recordDraftChange(previous, conversation: conversation, db: db)
        }
    }
}
