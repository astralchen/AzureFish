import AzureFishAPI
import Foundation
import GRDB
import Testing
@testable import AzureFishChat

@Suite("聊天详情设置、搜索和提醒来源")
struct ChatDetailsTests {
    /// 通过 JSON 字典构造目标测试业务值，编码或解码失败向上抛出。
    private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    /// 构造包含测试用户有效成员区间的虚构群会话。
    private func conversation(_ user: UUID, id: String = "chat") throws -> ChatConversation {
        try decode(ChatConversation.self, ["id": id, "kind": "group", "title": "测试", "ownerID": user.uuidString.lowercased(),
            "members": [["id": user.uuidString.lowercased(), "active": true, "intervals": [["joined": 1, "left": 0]],
                         "profile": ["id": user.uuidString.lowercased(), "nickname": "自己", "version": 1]]],
            "revision": 1, "boundaryRevision": 1, "latest": 1000, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]])
    }
    /// 构造指定内容或序列的虚构消息，供本地存储断言使用。
    private func message(_ index: Int, text: String, sender: String = "peer", revoked: Bool = false, conversation: String = "chat") throws -> ChatMessage {
        try decode(ChatMessage.self, messageJSON(index, text: text, sender: sender, revoked: revoked, conversation: conversation))
    }
    /// 构造指定正文、身份及撤回状态的消息 JSON 字典。
    private func messageJSON(_ index: Int, text: String, sender: String = "peer", revoked: Bool = false, conversation: String = "chat") -> [String: Any] {
        ["id": "message-\(index)", "conversationID": conversation, "clientID": "c-\(index)", "serverID": "s-\(index)",
         "senderID": sender, "deviceID": "device", "sequence": index, "createdAt": index * 1000, "revision": revoked ? 2 : 1,
         "kind": "text", "schemaVersion": 1, "text": text, "revoked": revoked, "assets": [],
         "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0]]
    }
    /// 创建唯一临时测试目录；调用方负责在测试结束时清理。
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// 验证首轮补拉只建立提醒基线且旧前台周期结果不提醒。
    @Test func notificationBaselineAndForegroundGeneration() {
        var gate = ChatIncomingNotificationGate()
        let background = gate.complete(gate.begin(hasCheckpoint: true))
        #expect(!background)
        gate.setEnabled(true)
        let first = gate.complete(gate.begin(hasCheckpoint: true))
        #expect(!first)
        let live = gate.complete(gate.begin(hasCheckpoint: true))
        #expect(live)
        let stale = gate.begin(hasCheckpoint: true)
        gate.setEnabled(false); gate.setEnabled(true)
        let outdated = gate.complete(stale)
        #expect(!outdated)
        let returning = gate.complete(gate.begin(hasCheckpoint: true))
        #expect(!returning)
        let fresh = gate.complete(gate.begin(hasCheckpoint: true))
        #expect(fresh)
        let snapshot = gate.complete(gate.begin(hasCheckpoint: false))
        #expect(!snapshot)
    }
    /// 验证偏好跨重开及清空保留且保持账号隔离。
    @Test func preferencesSurviveReopenAndClearButRemainAccountScoped() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 7, count: 32), url = root.appendingPathComponent("db")
        let store = try ChatStore(url: url, key: key, environment: "test", userID: user)
        #expect(try await store.conversationPreferences("chat") == .init())
        try await store.setConversationPreferences(.init(isPinned: true, isMuted: true), conversation: "chat")
        let changed = try await store.updateConversationPreferences(conversation: "chat", isMuted: false)
        #expect(changed.isPinned && !changed.isMuted)
        _ = try await store.updateConversationPreferences(conversation: "chat", isMuted: true)
        try await store.clear(conversation: "chat")
        try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "test", userID: user)
        #expect(try await reopened.conversationPreferences("chat") == .init(isPinned: true, isMuted: true))
        #expect(try await reopened.conversationPreferences("other") == .init())
        #expect(try await reopened.allConversationPreferences().count == 1)
        try await reopened.close()
        await #expect(throws: ChatStoreError.unavailable) { try await reopened.setConversationPreferences(.init(), conversation: "chat") }
        #expect(throws: (any Error).self) { _ = try ChatStore(url: url, key: key, environment: "other", userID: user) }
        let otherUser = UUID()
        #expect(throws: (any Error).self) { _ = try ChatStore(url: url, key: key, environment: "test", userID: otherUser) }
        let other = try ChatStore(url: root.appendingPathComponent("other-account"), key: Data(repeating: 17, count: 32), environment: "test", userID: otherUser)
        #expect(try await other.conversationPreferences("chat") == .init())
        try await other.close()
    }
    /// 验证四语言搜索、分页、可见权限及旧消息上下文。
    @Test func fourLanguageSearchPaginationVisibilityAndOldContext() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 8, count: 32), environment: "test", userID: user)
        try await store.save(conversation(user))
        for i in 1...260 { try await store.save(message(i, text: "聊天记录 聊天記錄 HELLO العربية \(i)")) }
        for query in ["记录", "記錄", "hello", "ＨＥＬＬＯ", "العربية"] {
            #expect(try await store.searchMessages(conversation: "chat", query: query).messages.count == 50)
        }
        let first = try await store.searchMessages(conversation: "chat", query: "hello")
        let next = try await store.searchMessages(conversation: "chat", query: "hello", before: first.next)
        #expect(Set(first.messages.map(\.id)).isDisjoint(with: Set(next.messages.map(\.id))))
        #expect(first.messages.first?.sequence == 260)
        #expect(try await store.messageContext("message-2", conversation: "chat").contains { $0.sequence == 2 })
        #expect(try await store.messageContext("message-2", conversation: "chat").count <= 101)
        #expect(try await store.searchMessages(conversation: "other", query: "hello").messages.isEmpty)
        #expect(try await store.searchMessages(conversation: "chat", query: "\" OR * : -").messages.isEmpty)
        #expect(try await store.searchMessages(conversation: "chat", query: "👩🏽‍💻").messages.isEmpty)
        try await store.hide(message: "message-260")
        try await store.save(message(259, text: "HELLO", revoked: true))
        let visible = try await store.searchMessages(conversation: "chat", query: "hello")
        #expect(visible.messages.first?.sequence == 258)
        #expect(try await store.visibleMessage("message-259", conversation: "chat") == nil)
        var restricted = try conversation(user)
        restricted.revision = 2
        restricted.members[0].intervals[0].joined = 250
        try await store.save(restricted)
        #expect(try await store.messageContext("message-2", conversation: "chat").isEmpty)
        #expect(try await store.searchMessages(conversation: "chat", query: "hello").messages.count == 9)
        try await store.clear(conversation: "chat")
        try await store.save(message(260, text: "HELLO"))
        #expect(try await store.searchMessages(conversation: "chat", query: "hello").messages.isEmpty)
        try await store.close()
    }
    /// 验证当前基线的文字索引可在关闭重开后继续使用。
    @Test func baselineKeepsTextIndexAcrossReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 9, count: 32), url = root.appendingPathComponent("db")
        let store = try ChatStore(url: url, key: key, environment: "test", userID: user)
        try await store.save(conversation(user)); try await store.save(message(1, text: "搜索繁體中文")); try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "test", userID: user)
        #expect(try await reopened.searchMessages(conversation: "chat", query: "繁體").messages.count == 1)
        try await reopened.close()
    }
    /// 验证来信候选只来自事务已提交的新消息。
    @Test func incomingCandidatesOnlyFollowCommittedNewMessages() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 6, count: 32), environment: "test", userID: user)
        try await store.save(conversation(user))
        try await store.saveCheckpoint(ChatCheckpoint(cursor: "0", epoch: "epoch"))
        let messages = [messageJSON(1, text: "new"), messageJSON(2, text: "self", sender: user.uuidString.lowercased()), messageJSON(3, text: "revoked", revoked: true)]
        let batch = try decode(ChatEvents.self, ["base": "0", "next": "3", "epoch": "epoch", "hasMore": false,
            "events": messages.enumerated().map { ["position": $0.offset + 1, "kind": "message", "message": $0.element] }])
        let incoming = try await store.apply(events: batch, expected: .init(cursor: "0", epoch: "epoch"))
        #expect(incoming.map(\.id) == ["message-1"])
        await #expect(throws: ChatStoreError.cursorMismatch) { try await store.apply(events: batch, expected: .init(cursor: "0", epoch: "epoch")) }
        let repeated = try decode(ChatEvents.self, ["base": "3", "next": "4", "epoch": "epoch", "hasMore": false,
            "events": [["position": 4, "kind": "message", "message": messages[0]]]])
        #expect(try await store.apply(events: repeated, expected: .init(cursor: "3", epoch: "epoch")).isEmpty)
        try await store.close()
    }
}
