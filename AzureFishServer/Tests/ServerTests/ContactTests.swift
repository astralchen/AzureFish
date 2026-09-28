import Foundation
import Testing
import VaporTesting

@testable import Server

func contactInput(_ peer: AuthResponse, action: String, revision: Int64 = 0) -> ContactMutationRequest {
    var value = ContactMutationRequest()
    value.operationID = UUID().uuidString
    value.peerUserID = peer.userID
    value.action = action
    value.expectedRevision = revision
    return value
}
func befriend(_ app: Application, _ a: AuthResponse, _ b: AuthResponse) async throws {
    let request = try await imCall(
        app, "contacts/mutate", contactInput(b, action: "request"), ContactRelationship.self, a)
    if request.state == "friend" { return }
    let receiver = request.requesterUserID == a.userID ? b : a
    let sender = request.requesterUserID == a.userID ? a : b
    do {
        _ = try await imCall(
            app, "contacts/mutate", contactInput(sender, action: "accept", revision: request.revision),
            ContactRelationship.self, receiver)
    } catch {
        var get = ContactGetRequest()
        get.peerUserID = b.userID
        guard try await imCall(app, "contacts/get", get, ContactRelationship.self, a).state == "friend" else {
            throw error
        }
    }
}
@Suite("好友权威关系", .serialized)
struct ContactTests {
    @Test func acceptanceDeletionAndOldRetries() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "friend_a")
            let b = try await auth(app, name: "friend_b")
            var resolve = IMResolveRequest()
            resolve.operationID = UUID().uuidString
            resolve.peerUserID = b.userID
            #expect(
                try errorCode(await send(app, .POST, "/v1/im/conversations/resolve", resolve, token: a.accessToken))
                    == "FRIEND_REQUIRED")
            let request = contactInput(b, action: "request")
            let pending = try await imCall(app, "contacts/mutate", request, ContactRelationship.self, a)
            let crossed = try await imCall(
                app, "contacts/mutate", contactInput(a, action: "request"), ContactRelationship.self, b)
            #expect(crossed.state == "pending" && crossed.requesterUserID == a.userID)
            #expect(
                try errorCode(
                    await send(
                        app, .POST, "/v1/im/contacts/mutate",
                        contactInput(b, action: "accept", revision: pending.revision), token: a.accessToken))
                    == "CONTACT_ACTION_UNAVAILABLE")
            let accept = contactInput(a, action: "accept", revision: pending.revision)
            let friend = try await imCall(app, "contacts/mutate", accept, ContactRelationship.self, b)
            let chat = try await imCall(app, "conversations/resolve", resolve, IMConversation.self, a)
            let input = outgoing(chat, a)
            let message = try await imCall(app, "messages/send", input, IMMessage.self, a)
            let deleted = try await imCall(
                app, "contacts/mutate", contactInput(b, action: "delete", revision: friend.revision),
                ContactRelationship.self, a)
            #expect(deleted.state == "deleted")
            #expect(try await imCall(app, "contacts/mutate", accept, ContactRelationship.self, b).state == "deleted")
            #expect(try await imCall(app, "contacts/mutate", request, ContactRelationship.self, a).state == "deleted")
            #expect(try await imCall(app, "messages/send", input, IMMessage.self, a).messageUuid == message.messageUuid)
            #expect(
                try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, a), token: a.accessToken))
                    == "FRIEND_REQUIRED")
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, b).messages.count == 2)
            let events = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            #expect(events.events.filter { $0.kind == "contact" }.allSatisfy { $0.contact.state == "deleted" })
            #expect(events.events.map(\.position) == Array(1...Int64(events.events.count)))
            let snapshot = try await imCall(app, "snapshot", IMSnapshotRequest(), IMSnapshotResponse.self, a)
            #expect(snapshot.contacts.first?.state == "deleted")
            let newRequest = try await imCall(
                app, "contacts/mutate", contactInput(b, action: "request", revision: deleted.revision),
                ContactRelationship.self, a)
            #expect(newRequest.state == "pending" && newRequest.revision > deleted.revision)
        }
    }
    @Test func groupRequiresOwnersFriends() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "friend_a")
            let b = try await auth(app, name: "friend_b")
            let c = try await auth(app, name: "friend_c")
            let chat = try await group(app, a, [b])
            let add = groupChange(chat, action: "add", target: c.userID)
            #expect(
                try errorCode(await send(app, .POST, "/v1/im/groups/update", add, token: a.accessToken))
                    == "FRIEND_REQUIRED")
            try await befriend(app, a, c)
            #expect(try await imCall(app, "groups/update", add, IMConversation.self, a).members.count == 3)
        }
    }
}
