import Fluent
import Foundation
import Testing
import VaporTesting
@testable import Server

@Suite("单向联系人与私有设置", .serialized)
struct ContactManagementTests {
    @Test func nicknameChangesReachContactsAndGroupMembersWithoutLosingRemarks() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "profile_a"), b = try await auth(app, name: "profile_b"), c = try await auth(app, name: "profile_c")
            try await befriend(app, a, b)
            try await befriend(app, a, c)
            let group = try await group(app, a, [b, c])
            let named = try await change(app, b, a, "remark", remark: "同事")
            let baseline = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            var request = UpdateProfileRequest(); request.operationID = UUID().uuidString
            request.expectedProfileVersion = a.profile.profileVersion; request.nickname = "新昵称"
            let updated = try await send(app, .PATCH, "/v1/me", request, token: a.accessToken)
            #expect(updated.status == .ok)
            var query = IMEventsRequest(); query.cursor = baseline.nextCursor; query.epoch = baseline.epoch
            let changes = try await imCall(app, "events", query, IMEventsResponse.self, b)
            #expect(changes.ownProfileVersion == b.profile.profileVersion)
            #expect(try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, a).ownProfileVersion == a.profile.profileVersion + 1)
            let contact = try #require(changes.events.first { $0.hasContact }?.contact)
            #expect(contact.remark == "同事" && contact.peer.nickname == "新昵称" && contact.revision > named.revision)
            #expect(contact.requestUpdatedAtMs == named.requestUpdatedAtMs)
            let conversation = try #require(changes.events.first { $0.conversation.conversationID == group.conversationID }?.conversation)
            #expect(conversation.members.first { $0.userID == a.userID }?.profile.nickname == "新昵称")
            let replay = try await send(app, .PATCH, "/v1/me", request, token: a.accessToken)
            #expect(replay.body == updated.body)
            query.cursor = changes.nextCursor
            #expect(try await imCall(app, "events", query, IMEventsResponse.self, b).events.isEmpty)
        }
    }
    @Test func ownProfileVersionAdvancesWithoutContactsOrConversations() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "profile_solo")
            let baseline = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, a)
            var update = UpdateProfileRequest(); update.operationID = UUID().uuidString
            update.expectedProfileVersion = a.profile.profileVersion; update.bio = "更新简介"
            #expect(try await send(app, .PATCH, "/v1/me", update, token: a.accessToken).status == .ok)
            let changed = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, a)
            #expect(changed.events.isEmpty && changed.nextCursor == baseline.nextCursor)
            #expect(changed.ownProfileVersion == baseline.ownProfileVersion + 1)
        }
    }
    private func view(_ app: Application, _ owner: AuthResponse, _ peer: AuthResponse) async throws -> ContactRelationship {
        var get = ContactGetRequest(); get.peerUserID = peer.userID
        return try await imCall(app, "contacts/get", get, ContactRelationship.self, owner)
    }
    private func change(_ app: Application, _ owner: AuthResponse, _ peer: AuthResponse, _ action: String,
                        remark: String = "", message: String = "") async throws -> ContactRelationship {
        let current = try await view(app, owner, peer)
        var input = contactInput(peer, action: action, revision: current.revision)
        input.remark = remark; input.requestMessage = message
        if ["accept", "reject", "cancel"].contains(action) { input.requestID = current.requestID }
        return try await imCall(app, "contacts/mutate", input, ContactRelationship.self, owner)
    }
    @Test func privateRemarksDeletionRestoreAndBlockMatrix() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "manage_a"), b = try await auth(app, name: "manage_b")
            let pending = try await change(app, a, b, "request", message: "你好，我是 A")
            #expect(pending.requestMessage == "你好，我是 A" && pending.requestState == "pending")
            _ = try await change(app, b, a, "accept")
            var resolve = IMResolveRequest(); resolve.operationID = UUID().uuidString; resolve.peerUserID = b.userID
            let chat = try await imCall(app, "conversations/resolve", resolve, IMConversation.self, a)
            let existingGroup = try await group(app, a, [b])
            let before = try await view(app, b, a)
            let eventsBefore = try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b)
            let renamed = try await change(app, a, b, "remark", remark: "设计同事")
            let unseen = try await view(app, b, a)
            #expect(renamed.remark == "设计同事" && unseen.remark.isEmpty && unseen.revision == before.revision)
            #expect(try await imCall(app, "events", IMEventsRequest(), IMEventsResponse.self, b).nextCursor == eventsBefore.nextCursor)
            _ = try await change(app, a, b, "delete")
            #expect(try await view(app, a, b).isContact == false)
            #expect(try await view(app, b, a).isContact == true)
            for user in [a, b] {
                #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, user), token: user.accessToken)) == "FRIEND_REQUIRED")
            }
            let restored = try await change(app, a, b, "restore")
            #expect(restored.canSendForTest && restored.remark == "设计同事")
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, a).messages.count == 1)
            _ = try await change(app, a, b, "block")
            #expect(try await view(app, a, b).isBlocked)
            #expect(try await view(app, b, a).isBlocked == false)
            for user in [a, b] {
                #expect(try errorCode(await send(app, .POST, "/v1/im/messages/send", outgoing(chat, user), token: user.accessToken)) == "CONTACT_UNAVAILABLE")
            }
            #expect(try await imCall(app, "messages/send", outgoing(existingGroup, a), IMMessage.self, a).contentType == "text")
            var create = IMCreateGroupRequest(); create.operationID = UUID().uuidString; create.title = "blocked"; create.memberUserIds = [b.userID]
            #expect(try errorCode(await send(app, .POST, "/v1/im/groups/create", create, token: a.accessToken)) == "CONTACT_UNAVAILABLE")
            var asset = MediaCreateRequest(); asset.operationID = UUID().uuidString; asset.kind = "file"; asset.conversationID = chat.conversationID
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "test.txt"; resource.mimeType = "text/plain"
            resource.byteCount = 3; resource.sha256 = LocalMediaBlobStore.hash(Data("abc".utf8)); asset.resources = [resource]
            #expect(try errorCode(await send(app, .POST, "/v1/media/assets/create", asset, token: a.accessToken)) == "CONTACT_UNAVAILABLE")
            _ = try await change(app, b, a, "block")
            _ = try await change(app, a, b, "unblock")
            #expect(try await view(app, a, b).canSendForTest == false)
            _ = try await change(app, b, a, "unblock")
            #expect(try await view(app, a, b).canSendForTest)
            _ = try await change(app, a, b, "delete"); _ = try await change(app, b, a, "delete")
            let request = try await change(app, b, a, "request", message: "重新认识")
            #expect(request.requestID != pending.requestID)
            _ = try await change(app, a, b, "accept")
            #expect(try await imCall(app, "history", historyInput(chat), IMHistoryResponse.self, a).messages.count == 2)
        }
    }
    @Test func pendingTerminationValidationAndVersionConflicts() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "request_a"), b = try await auth(app, name: "request_b")
            var old = contactInput(b, action: "request"); old.semanticsVersion = 0
            #expect(try errorCode(await send(app, .POST, "/v1/im/contacts/mutate", old, token: a.accessToken)) == "CONTACT_CLIENT_UPDATE_REQUIRED")
            var long = contactInput(b, action: "request"); long.requestMessage = String(repeating: "你", count: 201)
            #expect(try errorCode(await send(app, .POST, "/v1/im/contacts/mutate", long, token: a.accessToken)) == "VALIDATION_FAILED")
            let request = try await change(app, a, b, "request", message: "原申请")
            _ = try await change(app, b, a, "block")
            #expect(try await view(app, a, b).requestState == "cancelled")
            _ = try await change(app, b, a, "unblock")
            #expect(try await view(app, a, b).requestState == "cancelled")
            let later = try await change(app, a, b, "request", message: "新申请")
            var stale = contactInput(a, action: "accept", revision: later.revision); stale.requestID = request.requestID
            #expect(try errorCode(await send(app, .POST, "/v1/im/contacts/mutate", stale, token: b.accessToken)) == "CONTACT_VERSION_CONFLICT")
            _ = try await change(app, b, a, "reject")
            #expect(try await view(app, a, b).requestState == "rejected")
            _ = try await change(app, a, b, "request")
            #expect(try await change(app, a, b, "cancel").requestState == "cancelled")
        }
    }
    @Test func encryptedLegacyPayloadMigratesWithoutErasingHistory() async throws {
        try await withServer { app, fixture in
            let a = try await auth(app, name: "legacy_a"), b = try await auth(app, name: "legacy_b")
            try await befriend(app, a, b)
            let row = try #require(try await ContactRecord.query(on: app.db).first())
            let crypto = try Cryptography(key: fixture.key, environment: "test")
            let legacy = ContactState(status: "friend", requester: UUID(uuidString: a.userID)!, revision: 8, updated: 123)
            row.payload = try crypto.seal(JSONEncoder().encode(legacy), context: "contact:" + row.requireID().uuidString)
            try await row.save(on: app.db)
            try await UpgradeContactSides(crypto: crypto).prepare(on: app.db)
            #expect(try await view(app, a, b).canSendForTest)
            #expect(try await view(app, b, a).revision == 9)
            _ = try await change(app, a, b, "delete")
            #expect(try await view(app, b, a).isContact)
            #expect(try await IMMessageRecord.query(on: app.db).count() == 1)
        }
    }
}
private extension ContactRelationship {
    var canSendForTest: Bool { availableActions.contains("send") }
}
