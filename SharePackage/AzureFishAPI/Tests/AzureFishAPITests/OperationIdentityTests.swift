import Foundation
import Testing
import AzureFishAPI
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol

@Suite("IM 与媒体操作身份")
struct OperationIdentityTests {
    /// 验证直接发送接口默认生成新身份，网络重试及显式恢复保留原身份和正文。
    @Test(arguments: ["contact", "resolve", "group", "updateGroup", "revoke", "read", "delivered", "mediaCreate", "mediaComplete", "mediaCancel"])
    func defaultsCreateNewOperationsAndRetriesPreserveIdentity(kind: String) async throws {
        let environment = try APIEnvironment(identifier: "operation-test", baseURL: URL(string: "https://example.invalid")!)
        let transport = MockHTTPTransport { _, attempt in
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: Data())
        }
        let manager = APISessionManager(api: AccountAPI(environment: environment, transport: transport), store: MemorySessionStore())
        try await manager.install(SessionCredentials(environmentID: environment.identifier,
            userID: UUID(), deviceID: UUID(), sessionID: UUID(),
            accessToken: SessionToken(rawValue: String(repeating: "a", count: 43)),
            accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            refreshToken: SessionToken(rawValue: String(repeating: "r", count: 43)),
            refreshExpiresAt: Date(timeIntervalSince1970: 1_902_000_000), refreshGeneration: 1))
        let im = IMAPI(session: manager), media = MediaAPI(session: manager)
        let peer = UUID().uuidString.lowercased(), conversation = UUID().uuidString.lowercased()
        let message = UUID().uuidString.lowercased(), asset = UUID().uuidString.lowercased()
        func submit(id: UUID? = nil) async throws {
            switch kind {
            case "contact":
                if let id { _ = try await im.mutateContact(peer: peer, action: .remark, revision: 1, operationID: id, remark: "虚构备注") }
                else { _ = try await im.mutateContact(peer: peer, action: .remark, revision: 1, remark: "虚构备注") }
            case "resolve":
                if let id { _ = try await im.resolve(peer: peer, operationID: id) }
                else { _ = try await im.resolve(peer: peer) }
            case "group":
                if let id { _ = try await im.createGroup(title: "虚构群", members: [peer], operationID: id) }
                else { _ = try await im.createGroup(title: "虚构群", members: [peer]) }
            case "updateGroup":
                if let id { _ = try await im.updateGroup(conversation, revision: 1, action: .rename, title: "新群名", operationID: id) }
                else { _ = try await im.updateGroup(conversation, revision: 1, action: .rename, title: "新群名") }
            case "revoke":
                if let id { _ = try await im.revoke(conversation: conversation, message: message, operationID: id) }
                else { _ = try await im.revoke(conversation: conversation, message: message) }
            case "read", "delivered":
                if let id { _ = try await im.watermark(conversation: conversation, through: 1, read: kind == "read", operationID: id) }
                else { _ = try await im.watermark(conversation: conversation, through: 1, read: kind == "read") }
            case "mediaCreate":
                let resources = [ChatMediaInput(filename: "fictional.jpg", mime: "image/jpeg", bytes: 1, sha256: String(repeating: "a", count: 64))]
                if let id { _ = try await media.create(conversation: conversation, kind: "media_group", resources: resources, operationID: id) }
                else { _ = try await media.create(conversation: conversation, kind: "media_group", resources: resources) }
            default:
                if let id { _ = try await media.finish(asset, cancel: kind == "mediaCancel", operationID: id) }
                else { _ = try await media.finish(asset, cancel: kind == "mediaCancel") }
            }
        }
        func operationID(in request: HTTPRequest) throws -> UUID {
            let body = try #require(request.body)
            let value: String
            switch kind {
            case "contact": value = try ContactMutationRequest(serializedBytes: body).operationID
            case "resolve": value = try IMResolveRequest(serializedBytes: body).operationID
            case "group": value = try IMCreateGroupRequest(serializedBytes: body).operationID
            case "updateGroup": value = try IMUpdateGroupRequest(serializedBytes: body).operationID
            case "revoke": value = try IMRevokeRequest(serializedBytes: body).operationID
            case "read", "delivered": value = try IMWatermarkRequest(serializedBytes: body).operationID
            case "mediaCreate": value = try MediaCreateRequest(serializedBytes: body).operationID
            default: value = try MediaAssetMutation(serializedBytes: body).operationID
            }
            return try #require(UUID(uuidString: value))
        }
        try await submit()
        try await submit()
        var requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].body == requests[1].body)
        let firstID = try operationID(in: requests[0])
        #expect(try operationID(in: requests[2]) != firstID)
        try await submit(id: firstID)
        try await submit(id: firstID)
        requests = await transport.requests
        #expect(requests.count == 5)
        #expect(try operationID(in: requests[3]) == firstID)
        #expect(requests[3].body == requests[0].body && requests[4].body == requests[0].body)
    }

    /// 验证联系人默认生成的身份随原始字节保存，显式恢复不会创建替代身份。
    @Test func contactPreparationKeepsGeneratedIdentityInSavedBytes() throws {
        let peer = UUID().uuidString.lowercased()
        let first = try IMAPI.contactMutation(peer: peer, action: .remark, revision: 1, remark: "虚构备注")
        let second = try IMAPI.contactMutation(peer: peer, action: .remark, revision: 1, remark: "虚构备注")
        let firstRequest = try ContactMutationRequest(serializedBytes: first)
        let firstID = try #require(UUID(uuidString: firstRequest.operationID))
        #expect(try ContactMutationRequest(serializedBytes: second).operationID != firstID.uuidString.lowercased())
        let recovered = try IMAPI.contactMutation(peer: peer, action: .remark, revision: 1, operationID: firstID, remark: "虚构备注")
        #expect(first == recovered)
    }
}
