import AzureFishAPI
import CryptoKit
import Foundation
import Testing
@testable import AzureFishChat

@Suite("好友系统提示存储")
struct ChatFriendshipNoticeTests {
    /// 验证摘要不会伪造历史覆盖或恢复隐藏内容。
    @Test func summaryDoesNotInventCoverageOrRestoreHiddenContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let user = UUID(), url = root.appendingPathComponent("main.sqlite")
        let message: [String: Any] = ["id": "notice", "conversationID": "chat", "clientID": "", "serverID": "notice",
            "senderID": "", "deviceID": "", "sequence": 1, "createdAt": 100, "revision": 1,
            "kind": "system", "schemaVersion": 1, "text": "", "revoked": false, "assets": [],
            "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0],
            "systemEvent": ["kind": "friendship_accepted", "relationshipID": "pair", "relationshipRevision": 2,
                            "requesterID": user.uuidString.lowercased(), "accepterID": "peer"]]
        var json: [String: Any] = ["id": "chat", "kind": "direct", "title": "", "ownerID": "", "members": [],
            "revision": 1, "boundaryRevision": 1, "latest": 1, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 1, "through": 1, "revision": 2], "latestMessage": message]
        func decode() throws -> ChatConversation { try JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: json)) }
        let conversation = try decode()
        let store = try ChatStore(url: url, key: key, environment: "test", userID: user)
        try await store.save(conversation)
        #expect(try await store.latestVisibleMessage("chat")?.systemEvent?.kind == "friendship_accepted")
        #expect(try await store.messages("chat").isEmpty)
        #expect(try await store.coveredThrough(conversation: "chat", boundary: 1, from: 1) == 0)
        json.removeValue(forKey: "latestMessage")
        json["latest"] = 0
        json["readState"] = ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]
        let old = try decode()
        try await store.save(old)
        #expect(try await store.conversations().first?.latest == 1)
        try await store.clear(conversation: "chat")
        #expect(try await store.latestVisibleMessage("chat") == nil)
        try await store.save(try #require(conversation.latestMessage))
        #expect(try await store.messages("chat").isEmpty)
        try await store.close()
        let reopened = try ChatStore(url: url, key: key, environment: "test", userID: user)
        try await reopened.save(conversation)
        #expect(try await reopened.latestVisibleMessage("chat") == nil)
        try await reopened.close()
        var legacy = message; legacy.removeValue(forKey: "systemEvent")
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).systemEvent == nil)
    }
}
