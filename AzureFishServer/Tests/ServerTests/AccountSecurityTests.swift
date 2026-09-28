@testable import Server
import Foundation
import Testing
import VaporTesting
import Fluent
import CoreGraphics
import ImageIO

private func proof(_ app: Application, _ user: AuthResponse, action: String) async throws -> String {
    var request = ReauthenticateRequest(); request.operationID = UUID().uuidString
    request.password = registration().password; request.action = action
    let response = try await send(app, .POST, "/v1/auth/reauthenticate", request, token: user.accessToken)
    #expect(response.status == .ok)
    return try decode(ReauthenticateResponse.self, response).token
}
private func securityRequest(_ token: String, password: String = "") -> AccountSecurityRequest {
    var request = AccountSecurityRequest(); request.operationID = UUID().uuidString
    request.reauthToken = token; request.newPassword = password; return request
}
@Suite("账号安全闭环", .serialized)
struct AccountSecurityTests {
    @Test func changePasswordRevokesAllAndRecoversExactOperation() async throws {
        try await withServer { app, _ in
            let user = try await auth(app)
            var login = LoginRequest(); login.operationID = UUID().uuidString; login.deviceID = UUID().uuidString
            login.accountName = "test_account"; login.password = registration().password
            let other = try decode(AuthResponse.self, await send(app, .POST, "/v1/auth/login", login))
            let request = try await securityRequest(proof(app, user, action: "change_password"), password: "New-Fictional-Password-123")
            let response = try await send(app, .POST, "/v1/me/security/change_password", request, token: user.accessToken)
            #expect(response.status == .ok)
            #expect(try await me(app, user.accessToken).status == .unauthorized)
            #expect(try await me(app, other.accessToken).status == .unauthorized)
            #expect(try await send(app, .POST, "/v1/me/security/change_password", request, token: user.accessToken).status == .ok)
            var changed = request; changed.newPassword = "Another-Password-123"
            #expect(try errorCode(await send(app, .POST, "/v1/me/security/change_password", changed, token: user.accessToken)) == "OPERATION_CONFLICT")
            login.operationID = UUID().uuidString
            #expect(try await send(app, .POST, "/v1/auth/login", login).status == .unauthorized)
            login.operationID = UUID().uuidString; login.password = request.newPassword
            #expect(try await send(app, .POST, "/v1/auth/login", login).status == .ok)
        }
    }
    @Test func proofIsBoundToActionSessionAndExpiration() async throws {
        try await withServer { app, fixture in
            let a = try await auth(app), b = try await auth(app, name: "other_account")
            let token = try await proof(app, a, action: "logout_all")
            let request = securityRequest(token)
            #expect(try errorCode(await send(app, .POST, "/v1/me/security/logout_all", request, token: b.accessToken)) == "REAUTH_REQUIRED")
            #expect(try errorCode(await send(app, .POST, "/v1/me/security/delete_account", request, token: a.accessToken)) == "REAUTH_REQUIRED")
            fixture.clock.advance(301)
            #expect(try errorCode(await send(app, .POST, "/v1/me/security/logout_all", request, token: a.accessToken)) == "REAUTH_REQUIRED")
            #expect(try await me(app, a.accessToken).status == .ok)
        }
    }
    @Test func deletionRequiresOwnershipResolutionAndPreservesPeerHistory() async throws {
        try await withServer { app, _ in
            let a = try await auth(app), b = try await auth(app, name: "peer_account")
            let former = try await auth(app, name: "former_member")
            let chat = try await group(app, a, [b, former])
            _ = try await imCall(app, "messages/send", outgoing(chat, a), IMMessage.self, a)
            let request = try await securityRequest(proof(app, a, action: "delete_account"))
            #expect(try errorCode(await send(app, .POST, "/v1/me/security/delete_account", request, token: a.accessToken)) == "OWNER_TRANSFER_REQUIRED")
            var leave = IMUpdateGroupRequest(); leave.operationID = UUID().uuidString
            leave.conversationID = chat.conversationID; leave.expectedRevision = chat.serverRevision; leave.action = "leave"
            let closed = try await imCall(app, "groups/update", leave, IMConversation.self, former)
            var transfer = IMUpdateGroupRequest(); transfer.operationID = UUID().uuidString
            transfer.conversationID = chat.conversationID; transfer.expectedRevision = closed.serverRevision
            transfer.action = "transfer"; transfer.memberUserID = b.userID
            _ = try await imCall(app, "groups/update", transfer, IMConversation.self, a)
            #expect(try await send(app, .POST, "/v1/me/security/delete_account", request, token: a.accessToken).status == .accepted)
            #expect(try await send(app, .POST, "/v1/me/security/delete_account", request, token: a.accessToken).status == .accepted)
            #expect(try await me(app, a.accessToken).status == .unauthorized)
            var get = ContactGetRequest(); get.peerUserID = a.userID
            let contact = try await imCall(app, "contacts/get", get, ContactRelationship.self, b)
            #expect(contact.peer.deleted && !contact.availableActions.contains("send"))
            #expect(try await IMMessageRecord.query(on: app.db).filter(\.$conversationID == UUID(uuidString: chat.conversationID)!).count() == 1)
            let row = try #require(await UserRecord.find(UUID(uuidString: a.userID), on: app.db))
            let service = try #require(app.storage[AccountServiceKey.self])
            let payload = try service.payload(row)
            #expect(payload.deleted == true && payload.bio.isEmpty && payload.avatarJPEG == nil)
            let operations = try await OperationRecord.query(on: app.db).filter(\.$sessionID == UUID(uuidString: a.sessionID)!).all()
            #expect(operations.count == 1 && operations[0].scope.hasPrefix("delete_account:"))
            #expect(try await IMEventRecord.query(on: app.db).filter(\.$userID == UUID(uuidString: a.userID)!).count() == 0)
            var conversation = IMConversationRequest(); conversation.conversationID = chat.conversationID
            let historical = try await imCall(app, "conversations/get", conversation, IMConversation.self, former)
            #expect(historical.closed && historical.members.first { $0.userID == a.userID }?.profile.deleted == true)
        }
    }
    @Test func avatarVersionAuthorizationAndReset() async throws {
        try await withServer { app, _ in
            let a = try await auth(app), b = try await auth(app, name: "avatar_peer")
            let context = try #require(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            let data = NSMutableData(); let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil); #expect(CGImageDestinationFinalize(destination))
            var request = UpdateAvatarRequest(); request.operationID = UUID().uuidString
            request.expectedProfileVersion = 1; request.jpeg = data as Data
            let result = try await send(app, .POST, "/v1/me/avatar", request, token: a.accessToken)
            #expect(result.status == .ok)
            let profile = try decode(UserProfile.self, result); #expect(!profile.avatarID.isEmpty)
            #expect(try await send(app, .POST, "/v1/me/avatar", request, token: a.accessToken).body == result.body)
            let path = "/v1/users/" + a.userID + "/avatar"
            #expect(try await app.testing().sendRequest(.GET, path, headers: ["Authorization": "Bearer " + b.accessToken]).status == .notFound)
            try await befriend(app, a, b)
            let image = try await app.testing().sendRequest(.GET, path, headers: ["Authorization": "Bearer " + b.accessToken])
            #expect(try decode(AvatarResponse.self, image).jpeg == request.jpeg)
            request.operationID = UUID().uuidString; request.jpeg = Data()
            #expect(try errorCode(await send(app, .POST, "/v1/me/avatar", request, token: a.accessToken)) == "PROFILE_VERSION_CONFLICT")
            request.operationID = UUID().uuidString; request.expectedProfileVersion = profile.profileVersion
            #expect(try decode(UserProfile.self, await send(app, .POST, "/v1/me/avatar", request, token: a.accessToken)).avatarID.isEmpty)
        }
    }

    @Test func originalResultSurvivesAccessExpiryButNewActionDoesNot() async throws {
        try await withServer { app, fixture in
            let user = try await auth(app)
            fixture.clock.advance(14 * 60)
            let request = try await securityRequest(proof(app, user, action: "logout_all"))
            #expect(try await send(app, .POST, "/v1/me/security/logout_all", request, token: user.accessToken).status == .ok)
            fixture.clock.advance(2 * 60)
            #expect(try await send(app, .POST, "/v1/me/security/logout_all", request, token: user.accessToken).status == .ok)
            var other = request; other.operationID = UUID().uuidString
            #expect(try await send(app, .POST, "/v1/me/security/logout_all", other, token: user.accessToken).status == .unauthorized)
        }
    }
    @Test func startupResumesCommittedDeletionMarker() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let app = try await fixture.app()
        let user = try await auth(app)
        let request = try await securityRequest(proof(app, user, action: "delete_account"))
        #expect(try await send(app, .POST, "/v1/me/security/delete_account", request, token: user.accessToken).status == .accepted)
        let service = try #require(app.storage[AccountServiceKey.self])
        let marker = MetadataRecord(); marker.id = "account-delete:" + UUID(uuidString: user.userID)!.uuidString
        marker.value = try service.crypto.seal(Data(), context: marker.id!)
        try await marker.create(on: app.db)
        try await app.asyncShutdown()
        let restarted = try await fixture.app()
        #expect(try await MetadataRecord.find(marker.id, on: restarted.db) == nil)
        #expect(try await me(restarted, user.accessToken).status == .unauthorized)
        #expect(try await send(restarted, .POST, "/v1/me/security/delete_account", request, token: user.accessToken).status == .accepted)
        try await restarted.asyncShutdown()
    }
}
