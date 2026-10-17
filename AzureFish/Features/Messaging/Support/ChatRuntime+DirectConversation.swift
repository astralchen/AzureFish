import AzureFishAPI
import AzureFishChat
import Foundation

extension ChatRuntime {
    /// 仅使用本地资料打开私聊；无历史时返回按联系人隔离的空聊天，不调用网络接口。
    /// 临时页面只保存草稿和解析操作标识，不写入权威会话表。
    func directConversation(for contact: ChatContact) async throws -> ChatConversation {
        guard let engine else { throw ContactOperationError.unavailable }
        let localID = ChatStore.localDirectID(peer: contact.peer.id)
        let pending: Bool = try await engine.store.isDirectResolutionPending(localID)
        guard self.engine === engine else { throw CancellationError() }
        if !pending {
            if let existing = matchingDirectConversation(in: conversations, peer: contact.peer.id) { return existing }
            let stored = try await engine.store.conversations()
            guard self.engine === engine else { throw CancellationError() }
            if let existing = matchingDirectConversation(in: stored, peer: contact.peer.id) { return existing }
        }
        try await engine.store.setDirectResolutionPending(true, localID: localID)
        guard self.engine === engine else { throw CancellationError() }
        let peer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contact.peer))
        let value: [String: Any] = [
            "id": localID, "kind": "direct", "title": contact.displayName, "ownerID": userID,
            "members": [
                ["id": userID, "active": true, "intervals": [], "profile": ["id": userID, "nickname": session.profile?.nickname ?? "", "version": 0]],
                ["id": contact.peer.id, "active": true, "intervals": [], "profile": peer],
            ],
            "revision": 0, "boundaryRevision": 0, "latest": 0, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 0],
        ]
        return try JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// 首次实际发送时取得权威私聊并原子迁移草稿；重试复用账号库中的操作标识。
    /// 解析或迁移失败时抛出错误，调用者保留编辑器内容；已有权威会话直接返回。
    func resolveDirectConversationForSending(_ conversation: ChatConversation) async throws -> ChatConversation {
        guard let peer = ChatStore.localDirectPeer(conversation.id) else { return conversation }
        guard let engine else { throw ContactOperationError.unavailable }
        let stored = try await engine.store.conversations()
        guard self.engine === engine else { throw CancellationError() }
        let resolved: ChatConversation
        if let existing = matchingDirectConversation(in: stored, peer: peer) { resolved = existing }
        else {
            guard let api else { throw AccountFailure.offline }
            let operation = try await engine.store.directResolutionOperation(conversation.id)
            try Task.checkCancellation()
            guard self.engine === engine else { throw CancellationError() }
            resolved = try await api.resolve(peer: peer, operationID: operation)
        }
        try Task.checkCancellation()
        guard self.engine === engine else { throw CancellationError() }
        try await engine.store.bindLocalDirectDraft(conversation.id, to: resolved)
        guard self.engine === engine else { throw CancellationError() }
        changed()
        return resolved
    }

    /// 读取其他页面已完成的本地绑定，不发起网络解析。
    func boundDirectConversation(_ conversation: ChatConversation) async throws -> ChatConversation {
        guard ChatStore.localDirectPeer(conversation.id) != nil, let engine else { return conversation }
        let id = try await engine.store.canonicalDraftConversation(conversation.id)
        guard self.engine === engine else { throw CancellationError() }
        guard id != conversation.id else { return conversation }
        let stored = try await engine.store.conversations()
        guard self.engine === engine else { throw CancellationError() }
        return stored.first { $0.id == id } ?? conversation
    }

    private func matchingDirectConversation(in values: [ChatConversation], peer: String) -> ChatConversation? {
        let members = Set([userID, peer])
        return values.first { $0.kind == "direct" && Set($0.members.map(\.id)) == members }
    }
}
