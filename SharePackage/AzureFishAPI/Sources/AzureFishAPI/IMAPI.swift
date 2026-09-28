import AzureFishProtocol
import Foundation
import SwiftProtobuf

/// 在同一会话管理器中执行 IM 与好友操作，保留调用方提供的写入身份。
public struct IMAPI: Sendable {
    public let session: APISessionManager
    public init(session: APISessionManager) { self.session = session }

    func call<I: Message & Sendable, O: Message & Sendable, V: Sendable>(
        _ path: String, _ input: I, as output: O.Type,
        id: UUID? = nil, map: @escaping @Sendable (O) -> V
    ) async throws -> V {
        let credentials = try await session.credentials()
        let data = try input.serializedData()
        guard data.count <= 256 * 1024 else { throw APIClientError.requestTooLarge }
        var operation = AccountOperation<V>(
            operationID: id, environment: session.environment, path: path,
            method: .post, body: data, expectedStatus: 200, authorization: SessionIdentity(credentials)
        ) {
            map(try O(serializedBytes: $0))
        }
        operation.maximumResponseBytes = 4 * 1024 * 1024
        return try await session.execute(operation)
    }
    public func lookup(account: String) async throws -> ChatUser {
        var input = IMLookupUserRequest()
        input.accountName = account
        return try await call("v1/im/users/lookup", input, as: IMPublicUser.self, map: ChatUser.init)
    }
    public func contact(peer: String) async throws -> ChatContact {
        var input = ContactGetRequest()
        input.peerUserID = peer
        return try await call("v1/im/contacts/get", input, as: ContactRelationship.self, map: ChatContact.init)
    }
    public func mutateContact(peer: String, action: ContactAction, revision: Int64, operationID: UUID) async throws
        -> ChatContact
    {
        var input = ContactMutationRequest()
        input.peerUserID = peer
        input.action = action.rawValue
        input.expectedRevision = revision
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/contacts/mutate", input, as: ContactRelationship.self, id: operationID, map: ChatContact.init)
    }
    public func resolve(peer: String, operationID: UUID) async throws -> ChatConversation {
        var input = IMResolveRequest()
        input.peerUserID = peer
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/conversations/resolve", input, as: IMConversation.self, id: operationID, map: ChatConversation.init)
    }
    public func createGroup(title: String, members: [String], operationID: UUID) async throws -> ChatConversation {
        var input = IMCreateGroupRequest()
        input.title = title
        input.memberUserIds = members
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/groups/create", input, as: IMConversation.self, id: operationID, map: ChatConversation.init)
    }
    public func updateGroup(
        _ id: String, revision: Int64, action: GroupAction, title: String = "", member: String = "", operationID: UUID
    ) async throws -> ChatConversation {
        var input = IMUpdateGroupRequest()
        input.conversationID = id
        input.expectedRevision = revision
        input.action = action.rawValue
        input.title = title
        input.memberUserID = member
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/groups/update", input, as: IMConversation.self, id: operationID, map: ChatConversation.init)
    }
    public func conversation(_ id: String) async throws -> ChatConversation {
        var input = IMConversationRequest()
        input.conversationID = id
        return try await call("v1/im/conversations/get", input, as: IMConversation.self, map: ChatConversation.init)
    }
    public func snapshot(token: String = "", cursor: String = "") async throws -> ChatSnapshot {
        var input = IMSnapshotRequest()
        input.snapshotToken = token
        input.cursor = cursor
        return try await call("v1/im/snapshot", input, as: IMSnapshotResponse.self, map: ChatSnapshot.init)
    }
    public func events(cursor: String, epoch: String) async throws -> ChatEvents {
        var input = IMEventsRequest()
        input.cursor = cursor
        input.epoch = epoch
        return try await call("v1/im/events", input, as: IMEventsResponse.self, map: ChatEvents.init)
    }
    public func history(_ conversation: String, before: Int64 = 0, upper: Int64 = 0, boundary: Int64 = 0) async throws
        -> ChatHistory
    {
        var input = IMHistoryRequest()
        input.conversationID = conversation
        input.beforeSeq = before
        input.upperBoundSeq = upper
        input.boundaryRevision = boundary
        return try await call("v1/im/history", input, as: IMHistoryResponse.self, map: ChatHistory.init)
    }
    public func send(_ draft: ChatOutgoing) async throws -> ChatMessage {
        var input = IMSendRequest()
        input.operationID = draft.operationID.uuidString.lowercased()
        input.conversationID = draft.conversationID
        input.messageUuid = draft.id.uuidString.lowercased()
        input.clientMessageID = draft.clientID.uuidString.lowercased()
        input.deviceID = draft.deviceID.uuidString.lowercased()
        input.contentType = draft.kind
        input.contentSchemaVersion = 1
        input.text = draft.text
        input.assetIds = draft.assets
        input.textRuns = (draft.textRuns ?? []).map { run in
            var value = IMTextRun(); value.text = run.text; value.style = run.style; return value
        }
        input.linkURL = draft.linkURL ?? ""
        return try await call(
            "v1/im/messages/send", input, as: IMMessage.self, id: draft.operationID, map: ChatMessage.init)
    }
    public func revoke(conversation: String, message: String, operationID: UUID) async throws -> ChatMessage {
        var input = IMRevokeRequest()
        input.conversationID = conversation
        input.messageUuid = message
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/messages/revoke", input, as: IMMessage.self, id: operationID, map: ChatMessage.init)
    }
    public func watermark(conversation: String, through: Int64, read: Bool, operationID: UUID) async throws
        -> ChatConversation
    {
        var input = IMWatermarkRequest()
        input.conversationID = conversation
        input.throughSeq = through
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/" + (read ? "read" : "delivered"), input, as: IMConversation.self, id: operationID,
            map: ChatConversation.init)
    }
    public func receipts(conversation: String, message: String, token: String = "", cursor: String = "") async throws
        -> ChatReceipts
    {
        var input = IMReceiptsRequest()
        input.conversationID = conversation
        input.messageUuid = message
        input.snapshotToken = token
        input.cursor = cursor
        return try await call("v1/im/receipts", input, as: IMReceiptsResponse.self, map: ChatReceipts.init)
    }
}
public enum ContactAction: String, Codable, Sendable { case request, accept, reject, cancel, delete }
public enum GroupAction: String, Codable, Sendable { case rename, add, remove, leave, transfer, dissolve }
/// 可保存到加密 outbox 的不可变消息身份；同一条消息的网络重试复用所有字段。
public struct ChatOutgoing: Codable, Sendable, Equatable {
    public let id: UUID
    public let clientID: UUID
    public let operationID: UUID
    public let deviceID: UUID
    public let conversationID: String
    public let kind: String
    public let text: String
    public let assets: [String]
    public let textRuns: [ChatTextRun]?
    public let linkURL: String?
    public init(
        conversationID: String, deviceID: UUID, kind: String = "text", text: String = "", assets: [String] = [],
        id: UUID = UUID(), clientID: UUID = UUID(), operationID: UUID = UUID(),
        textRuns: [ChatTextRun]? = nil, linkURL: String? = nil
    ) {
        self.id = id
        self.clientID = clientID
        self.operationID = operationID
        self.deviceID = deviceID
        self.conversationID = conversationID
        self.kind = kind
        self.text = text
        self.assets = assets
        self.textRuns = textRuns
        self.linkURL = linkURL
    }
}
