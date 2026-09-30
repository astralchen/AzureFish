import AzureFishAPI
import Foundation
import GRDB
import Testing
@testable import AzureFishChat

@Suite("会话列表显示、隐藏与手动未读")
struct ChatConversationListTests {
    /// 会话列表测试共用的固定虚构用户身份。
    private let user = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    /// 通过 JSON 字典构造目标测试业务值，编码或解码失败向上抛出。
    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    /// 构造包含测试用户有效成员区间的虚构群会话。
    private func conversation() throws -> ChatConversation {
        try decode(["id": "chat", "kind": "group", "title": "测试", "ownerID": user.uuidString.lowercased(),
            "members": [["id": user.uuidString.lowercased(), "active": true, "intervals": [["joined": 1, "left": 0]],
                "profile": ["id": user.uuidString.lowercased(), "nickname": "自己", "version": 1]]],
            "revision": 1, "boundaryRevision": 1, "latest": 0, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]])
    }
    /// 构造指定内容或序列的虚构消息，供本地存储断言使用。
    private func message(_ sequence: Int, system: Bool = false) throws -> ChatMessage {
        try decode(["id": "m\(sequence)", "conversationID": "chat", "clientID": "c\(sequence)", "serverID": "s\(sequence)",
            "senderID": user.uuidString.lowercased(), "deviceID": "test", "sequence": sequence, "createdAt": sequence * 1000,
            "revision": 1, "kind": system ? "system" : "text", "schemaVersion": 1, "text": "测试", "revoked": false,
            "assets": [], "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0]])
    }
    /// 将消息列表封装为固定 1～10 连续覆盖区间的虚构历史页。
    private func history(_ messages: [ChatMessage]) throws -> ChatHistory {
        try decode(["messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
            "upper": 10, "before": 0, "hasMore": false, "coveredFrom": 1, "coveredThrough": 10,
            "boundary": 1, "earliest": 1])
    }
    /// 在给定目录打开固定虚构密钥和账号的列表测试存储。
    private func store(_ root: URL) throws -> ChatStore {
        try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 17, count: 32), environment: "list-tests", userID: user)
    }
    /// 创建唯一临时测试目录；调用方负责在测试结束时清理。
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 验证首次内容、清空、隐藏及重开遵循会话可见性规则。
    @Test func firstContentClearHideAndReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        try await store.save(message(1, system: true))
        #expect(try await store.conversationListStates()["chat"]?.isVisible != true)
        try await store.save(message(2))
        try await store.saveDraft(.init(text: "草稿"), conversation: "chat")
        try await store.setManuallyUnread(true, conversation: "chat")
        let before = try #require(await store.conversationListStates()["chat"])
        #expect(before.isVisible && before.manuallyUnread)
        try await store.clear(conversation: "chat")
        #expect(try await store.latestVisibleMessage("chat") == nil)
        #expect(try await store.conversationListStates()["chat"] == before)
        try await store.hideConversation("chat")
        try await store.save(message(2))
        try await store.apply(history: history([message(3)]), conversation: "chat")
        // 已由历史加载的消息更新不能冒充新消息解除隐藏。
        try await store.save(message(3))
        try await store.save(message(4, system: true))
        var revoked = try message(5); revoked.revoked = true
        try await store.save(revoked)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        #expect(try await store.conversationListStates()["chat"]?.manuallyUnread == false)
        try await store.close()
        let reopened = try self.store(root)
        #expect(try await reopened.conversationListStates()["chat"]?.isVisible == false)
        try await reopened.save(message(6))
        #expect(try await reopened.conversationListStates()["chat"]?.isVisible == true)
        #expect(try await reopened.draft("chat").text == "草稿")
        try await reopened.close()
    }

    /// 验证隐藏保留历史，删除列表项保留待发任务、草稿及偏好。
    @Test func hideKeepsHistoryAndDeleteKeepsPendingDraftAndPreferences() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        try await store.save(message(1))
        try await store.hideConversation("chat")
        #expect(try await store.messages("chat").count == 1)
        let outgoing = ChatOutgoing(conversationID: "chat", deviceID: UUID(), kind: "text", text: "待发送", assets: [])
        try await store.enqueueComposition([.message(outgoing)], conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.saveDraft(.init(text: "保留"), conversation: "chat")
        try await store.setConversationPreferences(.init(isPinned: true, isMuted: true), conversation: "chat")
        try await store.setManuallyUnread(true, conversation: "chat")
        try await store.hideConversation("chat", clearHistory: true)
        #expect(try await store.messages("chat").isEmpty)
        #expect(try await store.pending().count == 1)
        #expect(try await store.draft("chat").text == "保留")
        #expect(try await store.conversationPreferences("chat") == .init(isPinned: true, isMuted: true))
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        #expect(try await store.conversationListStates()["chat"]?.manuallyUnread == false)
        #expect(try await store.conversations().first?.readState.read == 0)
        try await store.save(message(1))
        #expect(try await store.messages("chat").isEmpty)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        try await store.close()
    }

    /// 验证删除事务回滚时历史和列表状态同时保留。
    @Test func deleteRollbackKeepsHistoryAndListState() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        try await store.save(message(1))
        let db = await store.db
        try db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_list BEFORE UPDATE ON conversation_local_state BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        do { try await store.hideConversation("chat", clearHistory: true); Issue.record("Write must fail") } catch {}
        #expect(try await store.messages("chat").count == 1)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.close()
    }

    /// 验证快照摘要与本机未读提醒保持各自语义。
    @Test func snapshotSummaryAndUnreadAreLocal() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        var conversation = try conversation()
        conversation.latest = 2; conversation.latestMessage = try message(2)
        try await store.save(conversation)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.setManuallyUnread(true, conversation: "chat")
        try await store.save(conversation)
        #expect(try await store.conversationListStates()["chat"]?.manuallyUnread == true)
        try await store.setManuallyUnread(false, conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.manuallyUnread == false)
        try await store.hideConversation("chat")
        try await store.save(conversation)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        conversation.latest = 3; conversation.latestMessage = try message(3)
        try await store.save(conversation)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        #expect(try await store.conversations().first?.readState.read == 0)
        try await store.close()
    }
    /// 验证历史发现及失败发送正确影响列表可见性。
    @Test func historyDiscoveryAndFailedSending() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        var conversation = try conversation()
        conversation.latest = 4; conversation.latestMessage = try message(4, system: true)
        try await store.save(conversation)
        #expect(try await store.conversationListStates()["chat"]?.isVisible != true)
        try await store.apply(history: history([message(2)]), conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.hideConversation("chat")
        try await store.apply(history: history([message(2)]), conversation: "chat", restoringListVisibility: true)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        try await store.apply(history: history([message(5)]), conversation: "chat", restoringListVisibility: true)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.hideConversation("chat")
        let outgoing = ChatOutgoing(conversationID: "chat", deviceID: UUID(), kind: "text", text: "离线内容", assets: [])
        try await store.enqueue(outgoing)
        var pending = try #require(await store.pending().first)
        pending.state = "failed"
        try await store.update(pending)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.close()
    }

    /// 验证只有草稿内容变化恢复隐藏会话且不推进活动排序。
    @Test func draftRestoresOnlyOnContentChangeAndDoesNotReorder() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        try await store.saveDraft(.init(text: "未发送"), conversation: "chat")
        var snapshot = try await store.conversationListSnapshot()
        #expect(snapshot.states["chat"]?.isVisible == true)
        #expect(snapshot.states["chat"]?.activityAt == 0)
        #expect(snapshot.drafts["chat"]?.text == "未发送")
        try await store.save(message(1))
        try await store.hideConversation("chat")
        try await store.saveDraft(.init(text: "未发送"), conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        try await store.saveDraft(.init(text: "继续编辑"), conversation: "chat")
        snapshot = try await store.conversationListSnapshot()
        #expect(snapshot.states["chat"]?.isVisible == true)
        #expect(snapshot.states["chat"]?.activityAt == 1000)
        try await store.saveDraft(.init(), conversation: "chat")
        snapshot = try await store.conversationListSnapshot()
        #expect(snapshot.drafts.isEmpty)
        #expect(snapshot.states["chat"]?.isVisible == true)
        try await store.setPinnedConversationsCollapsed(true)
        try await store.close()
        let reopened = try self.store(root)
        #expect(try await reopened.conversationListSnapshot().pinnedCollapsed)
        #expect(try await reopened.conversationListStates()["chat"]?.activityAt == 1000)
        try await reopened.close()
    }

    /// 验证附件草稿恢复、原子发送及失败回滚。
    @Test func attachmentDraftHydrationAtomicSendAndRollback() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        let attachment = ChatUploadItem(kind: "image", resources: [])
        try await store.saveDraftAttachments([attachment], conversation: "chat")
        #expect(try await store.conversationListSnapshot().drafts["chat"]?.hasAttachments == true)
        #expect(try await store.conversationListStates()["chat"]?.isVisible == true)
        try await store.hideConversation("chat")
        try await store.saveDraftAttachments([attachment], conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        let richAttachment = StoredDraftAttachment.file(.init(id: attachment.id, resourceID: UUID(), displayName: "file", typeIdentifier: "public.data", byteCount: 1))
        try await store.saveEditorDraft(StoredChatDraft(conversationID: "chat", documents: [richAttachment]), text: "", conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        try await store.saveEditorDraft(StoredChatDraft(revision: 1, conversationID: "chat", documents: [richAttachment]), text: "", conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        let database = await store.db
        try database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_draft_list BEFORE UPDATE ON conversation_local_state BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        do { try await store.saveDraft(.init(text: "不能提交"), conversation: "chat"); Issue.record("Write must fail") } catch {}
        #expect(try await store.draft("chat").text.isEmpty)
        #expect(try await store.conversationListSnapshot().drafts["chat"]?.hasAttachments == true)
        try database.write { try $0.execute(sql: "DROP TRIGGER reject_draft_list") }
        try await store.enqueueComposition([.message(.init(conversationID: "chat", deviceID: UUID(), kind: "text", text: "发送", assets: []))], conversation: "chat")
        let snapshot = try await store.conversationListSnapshot()
        #expect(snapshot.drafts.isEmpty)
        #expect(snapshot.states["chat"]?.isVisible == true)
        #expect(try await store.pending().count == 1)
        try await store.close()
    }

}
