@testable import Server
import Fluent
import Foundation
import SQLKit
import Testing
import VaporTesting

@Suite("好友通过双向提醒", .serialized)
struct FriendshipNoticeTests {
    @Test func bothUnreadReplayReaddAndUnauthorizedActions() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "notice_a"), b = try await auth(app, name: "notice_b")
            let pending = try await imCall(app, "contacts/mutate", contactInput(b, action: "request"), ContactRelationship.self, a)
            let accept = contactInput(a, action: "accept", revision: pending.revision)
            async let first = imCall(app, "contacts/mutate", accept, ContactRelationship.self, b)
            async let duplicate = imCall(app, "contacts/mutate", accept, ContactRelationship.self, b)
            let (friend, replay) = try await (first, duplicate)
            #expect(friend == replay)
            let snapshot = try await imCall(app, "snapshot", IMSnapshotRequest(), IMSnapshotResponse.self, a)
            let chat = try #require(snapshot.conversations.first)
            let notice = chat.latestMessage
            #expect(chat.latestSeq == 1 && chat.readState.unreadCount == 1)
            #expect(notice.contentType == "system" && notice.systemEvent.kind == "friendship_accepted")
            #expect(notice.systemEvent.requesterUserID == a.userID && notice.systemEvent.accepterUserID == b.userID)
            #expect(notice.systemEvent.relationshipRevision == friend.revision)
            #expect(notice.senderUserID.isEmpty && notice.deviceID.isEmpty && notice.text.isEmpty && !notice.hasReceipt)
            let other = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b)
            #expect(other.latestMessage == notice && other.readState.unreadCount == 1)
            #expect(try await IMMessageRecord.query(on: app.db).count() == 1)
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, b).messages == [notice])
            for user in [a, b] {
                let events = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, user)
                #expect(events.events.filter(\.hasMessage).map(\.message.messageUuid) == [notice.messageUuid])
                var revoke = IMRevokeRequest(); revoke.operationID = UUID().uuidString
                revoke.conversationID = chat.conversationID; revoke.messageUuid = notice.messageUuid
                #expect(try errorCode(await send(app, .POST, "/v1/im/messages/revoke", revoke, token: user.accessToken)) == "REVOKE_FORBIDDEN")
                var receipts = IMReceiptsRequest(); receipts.conversationID = chat.conversationID; receipts.messageUuid = notice.messageUuid
                #expect(try errorCode(await send(app, .POST, "/v1/im/receipts", receipts, token: user.accessToken)) == "RECEIPT_FORBIDDEN")
            }
            var forged = outgoing(chat, a); forged.contentType = "system"
            #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", forged, token: a.accessToken)) == "UNSUPPORTED_CONTENT")
            #expect(try await imCall(app, "read", watermark(chat, through: 1), IMReadState.self, a).unreadCount == 0)
            #expect(try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, b).readState.unreadCount == 1)
            _ = try await imCall(app, "read", watermark(chat, through: 1), IMReadState.self, b)
            let deleted = try await imCall(app, "contacts/mutate", contactInput(b, action: "delete", revision: friend.revision), ContactRelationship.self, a)
            #expect(try await imCall(app, "contacts/mutate", accept, ContactRelationship.self, b).state == "deleted")
            let request = try await imCall(app, "contacts/mutate", contactInput(b, action: "request", revision: deleted.revision), ContactRelationship.self, a)
            _ = try await imCall(app, "contacts/mutate", contactInput(a, action: "accept", revision: request.revision), ContactRelationship.self, b)
            let updated = try await imCall(app, "conversations/get", conversationInput(chat), IMConversation.self, a)
            #expect(updated.latestSeq == 2 && updated.readState.unreadCount == 1)
            #expect(updated.latestMessage.messageUuid != notice.messageUuid)
            #expect(try await IMConversationRecord.query(on: app.db).count() == 1)
        }
    }

    @Test func databaseFailureRollsBackRelationshipAndNotice() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "rollback_a"), b = try await auth(app, name: "rollback_b")
            let pending = try await imCall(app, "contacts/mutate", contactInput(b, action: "request"), ContactRelationship.self, a)
            let accept = contactInput(a, action: "accept", revision: pending.revision)
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TRIGGER fail_notice BEFORE INSERT ON im_messages BEGIN SELECT RAISE(ABORT, 'injected'); END").run()
            #expect(try await send(app, .POST, "/v1/im/contacts/mutate", accept, token: b.accessToken).status == .internalServerError)
            var get = ContactGetRequest(); get.peerUserID = a.userID
            #expect(try await imCall(app, "contacts/get", get, ContactRelationship.self, b).state == "pending")
            #expect(try await IMConversationRecord.query(on: app.db).count() == 0)
            #expect(try await IMMessageRecord.query(on: app.db).count() == 0)
            try await sql.raw("DROP TRIGGER fail_notice").run()
            #expect(try await imCall(app, "contacts/mutate", accept, ContactRelationship.self, b).state == "friend")
            #expect(try await IMMessageRecord.query(on: app.db).count() == 1)
        }
    }
    @Test func restartAndConversationLimitPreserveAtomicity() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let app = try await fixture.app()
        let a: AuthResponse, b: AuthResponse, accept: ContactMutationRequest
        do {
            a = try await auth(app, name: "restart_notice_a"); b = try await auth(app, name: "restart_notice_b")
            let pending = try await imCall(app, "contacts/mutate", contactInput(b, action: "request"), ContactRelationship.self, a)
            accept = contactInput(a, action: "accept", revision: pending.revision)
            // 容量占位仅参与成员计数，不读写真实会话密文。
            for _ in 0..<500 {
                let row = IMConversationRecord(); row.id = UUID(); row.pairKey = UUID().uuidString; row.payload = "capacity-fixture"
                try await row.create(on: app.db)
                let member = IMMemberRecord(); member.id = UUID(); member.userID = UUID(uuidString: b.userID)!
                member.conversationID = try row.requireID(); try await member.create(on: app.db)
            }
            #expect(try errorCode(await send(app, .POST, "/v1/im/contacts/mutate", accept, token: b.accessToken)) == "CONVERSATION_LIMIT")
            var get = ContactGetRequest(); get.peerUserID = a.userID
            #expect(try await imCall(app, "contacts/get", get, ContactRelationship.self, b).state == "pending")
            #expect(try await IMMessageRecord.query(on: app.db).count() == 0)
            try await IMMemberRecord.query(on: app.db).delete()
            try await IMConversationRecord.query(on: app.db).delete()
            _ = try await imCall(app, "contacts/mutate", accept, ContactRelationship.self, b)
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
        let reopened = try await fixture.app()
        do {
            _ = try await imCall(reopened, "contacts/mutate", accept, ContactRelationship.self, b)
            for user in [a, b] {
                let snapshot = try await imCall(reopened, "snapshot", IMSnapshotRequest(), IMSnapshotResponse.self, user)
                #expect(snapshot.conversations.count == 1 && snapshot.conversations[0].readState.unreadCount == 1)
                #expect(snapshot.conversations[0].latestMessage.contentType == "system")
            }
            #expect(try await IMMessageRecord.query(on: reopened.db).count() == 1)
        } catch { try await reopened.asyncShutdown(); throw error }
        try await reopened.asyncShutdown()
    }

}
