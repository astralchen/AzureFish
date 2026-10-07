@testable import Server
import Fluent
import Foundation
import Testing

@Suite("加密未读投影", .serialized)
struct IMUnreadProjectionTests {
    @Test func projectionMatchesHistoryAndRebuildsLegacyPayload() async throws {
        try await withServer { app, fixture in
            let a = try await auth(app, name: "projection_a"), b = try await auth(app, name: "projection_b")
            let chat = try await direct(app, a, b)
            var sent: [IMMessage] = []
            for _ in 0..<8 { sent.append(try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)) }
            for _ in 0..<3 { _ = try await imCall(app, "messages/send", outgoing(chat, b), IMMessage.self, b) }
            func compare() async throws {
                for user in [a, b] {
                    let view = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, user)
                    let history = try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, user)
                    let count = history.messages.filter { !$0.revoked && $0.serverSeq > view.readState.readThroughSeq && $0.senderUserID != user.userID }.count
                    #expect(view.readState.unreadCount == Int64(count))
                }
            }
            try await compare()
            _ = try await imCall(app, "read", watermark(chat, through: 4), IMReadState.self, b)
            var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString
            revoke.conversationID = chat.conversationID; revoke.messageUuid = sent[6].messageUuid
            _ = try await imCall(app, "messages/revoke", revoke, IMMessage.self, a)
            try await compare()
            let crypto = try Cryptography(key: fixture.key, environment: "test")
            let row = try #require(await IMConversationRecord.find(UUID(uuidString: chat.conversationID), on: app.db))
            let context = "conversation:" + (try row.requireID()).uuidString
            var state = try JSONDecoder().decode(IMConversationState.self, from: crypto.open(row.payload, context: context))
            for i in state.members.indices { state.members[i].unread = nil }
            row.payload = try crypto.seal(JSONEncoder().encode(state), context: context)
            try await row.update(on: app.db)
            try await compare()
            let restored = try #require(await IMConversationRecord.find(row.id, on: app.db))
            let projection = try JSONDecoder().decode(IMConversationState.self, from: crypto.open(restored.payload, context: context))
            #expect(projection.members.allSatisfy { $0.unread?.version == 1 })
            _ = try await imCall(app, "read", watermark(chat, through: 12), IMReadState.self, b)
            try await compare()
        }
    }
    @Test func closedMembershipAndRejoinRetainVisibleUnreadOnly() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "projection_a"), b = try await auth(app, name: "projection_b")
            var chat = try await group(app, a, [b])
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "remove", target: b.userID), IMConversation.self, a)
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.unreadCount == 1)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "add", target: b.userID), IMConversation.self, a)
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.unreadCount == 2)
            chat = try await imCall(app, "groups/update", groupChange(chat, action: "dissolve"), IMConversation.self, a)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.unreadCount == 2)
            _ = try await imCall(app, "read", watermark(chat, through: 3), IMReadState.self, b)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.unreadCount == 0)
        }
    }
}
