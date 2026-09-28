import AzureFishAPI
import Foundation
import GRDB
import Testing
@testable import AzureFishChat

@Suite("会话列表显示、隐藏与手动未读")
struct ChatConversationListTests {
    private let user = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func conversation() throws -> ChatConversation {
        try decode(["id": "chat", "kind": "group", "title": "测试", "ownerID": user.uuidString.lowercased(),
            "members": [["id": user.uuidString.lowercased(), "active": true, "intervals": [["joined": 1, "left": 0]],
                "profile": ["id": user.uuidString.lowercased(), "nickname": "自己", "version": 1]]],
            "revision": 1, "boundaryRevision": 1, "latest": 0, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]])
    }
    private func message(_ sequence: Int, system: Bool = false) throws -> ChatMessage {
        try decode(["id": "m\(sequence)", "conversationID": "chat", "clientID": "c\(sequence)", "serverID": "s\(sequence)",
            "senderID": user.uuidString.lowercased(), "deviceID": "test", "sequence": sequence, "createdAt": sequence * 1000,
            "revision": 1, "kind": system ? "system" : "text", "schemaVersion": 1, "text": "测试", "revoked": false,
            "assets": [], "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0]])
    }
    private func history(_ messages: [ChatMessage]) throws -> ChatHistory {
        try decode(["messages": try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages)),
            "upper": 10, "before": 0, "hasMore": false, "coveredFrom": 1, "coveredThrough": 10,
            "boundary": 1, "earliest": 1])
    }
    private func store(_ root: URL) throws -> ChatStore {
        try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 17, count: 32), environment: "list-tests", userID: user)
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

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

    @Test func migrationAndDeleteRollback() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root)
        try await store.save(conversation())
        try await store.save(message(1))
        let db = await store.db
        try await db.write { db in
            try db.execute(sql: "DROP TABLE conversation_list")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='chat-v5-conversation-list'")
        }
        try await store.close()
        let migrated = try self.store(root)
        #expect(try await migrated.conversationListStates()["chat"]?.isVisible == true)
        let migratedDB = await migrated.db
        try await migratedDB.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_list BEFORE INSERT ON conversation_list BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        do { try await migrated.hideConversation("chat", clearHistory: true); Issue.record("Write must fail") } catch {}
        #expect(try await migrated.messages("chat").count == 1)
        #expect(try await migrated.conversationListStates()["chat"]?.isVisible == true)
        try await migrated.close()
    }

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
        struct Rich: Codable, Sendable { var documents: [ChatUploadItem]; var revision: Int }
        try await store.saveEditorDraft(Rich(documents: [attachment], revision: 0), text: "", conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        try await store.saveEditorDraft(Rich(documents: [attachment], revision: 1), text: "", conversation: "chat")
        #expect(try await store.conversationListStates()["chat"]?.isVisible == false)
        let database = await store.db
        try await database.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_draft_list BEFORE INSERT ON conversation_list BEGIN SELECT RAISE(ABORT, 'test'); END")
        }
        do { try await store.saveDraft(.init(text: "不能提交"), conversation: "chat"); Issue.record("Write must fail") } catch {}
        #expect(try await store.draft("chat").text.isEmpty)
        #expect(try await store.conversationListSnapshot().drafts["chat"]?.hasAttachments == true)
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_draft_list") }
        try await store.enqueueComposition([.message(.init(conversationID: "chat", deviceID: UUID(), kind: "text", text: "发送", assets: []))], conversation: "chat")
        let snapshot = try await store.conversationListSnapshot()
        #expect(snapshot.drafts.isEmpty)
        #expect(snapshot.states["chat"]?.isVisible == true)
        #expect(try await store.pending().count == 1)
        try await store.close()
    }

}
