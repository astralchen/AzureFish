import AzureFishProtocol
import Foundation
import SwiftProtobuf

/// 在同一会话管理器中执行 IM 与好友操作，保留调用方提供的写入身份。
public struct IMAPI: Sendable {
    /// 所有 IM 操作共享的账号会话管理器。
    public let session: APISessionManager
    /// 绑定会话管理器；不发起请求或创建聊天数据。
    public init(session: APISessionManager) { self.session = session }

    /// 编码不超过 256 KiB 的 Protobuf 请求，在共享会话下执行并映射响应；响应上限为 4 MiB。
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
    /// 按账号名查询公开用户资料；输入原样交给服务端解释。
    public func lookup(account: String) async throws -> ChatUser {
        var input = IMLookupUserRequest()
        input.accountName = account
        return try await call("v1/im/users/lookup", input, as: IMPublicUser.self, map: ChatUser.init)
    }
    /// 查询当前账号与指定用户之间的联系人投影。
    public func contact(peer: String) async throws -> ChatContact {
        var input = ContactGetRequest()
        input.peerUserID = peer
        return try await call("v1/im/contacts/get", input, as: ContactRelationship.self, map: ChatContact.init)
    }
    /// 编码联系人操作；调用方可将返回字节保存在账号加密库中以恢复同一次操作。
    public static func contactMutation(peer: String, action: ContactAction, revision: Int64, operationID: UUID,
                                       remark: String = "", message: String = "", requestID: String = "") throws -> Data {
        var input = ContactMutationRequest()
        input.peerUserID = peer; input.action = action.rawValue; input.expectedRevision = revision
        input.operationID = operationID.uuidString.lowercased(); input.semanticsVersion = 2
        input.remark = remark; input.requestMessage = message; input.requestID = requestID
        return try input.serializedData()
    }
    /// 发送已保存的联系人修改字节并返回权威关系；不会重新编码请求。
    ///
    /// - Parameter bytes: 不超过 16 KiB 的原始 Protobuf 请求，须包含有效操作 UUID 和语义版本 2。
    /// - Throws: 请求超限、无法解码、身份或版本无效，以及共享会话执行错误。
    public func mutateContact(bytes: Data) async throws -> ChatContact {
        guard bytes.count <= 16 * 1024 else { throw APIClientError.requestTooLarge }
        let input = try ContactMutationRequest(serializedBytes: bytes)
        guard let id = UUID(uuidString: input.operationID), input.semanticsVersion == 2 else { throw APIClientError.invalidRequest }
        let credentials = try await session.credentials()
        let operation = AccountOperation<ChatContact>(operationID: id, environment: session.environment,
            path: "v1/im/contacts/mutate", method: .post, body: bytes, expectedStatus: 200,
            authorization: SessionIdentity(credentials)) { ChatContact(try ContactRelationship(serializedBytes: $0)) }
        return try await session.execute(operation)
    }
    /// 提交联系人修改并返回权威关系；同一动作重试必须复用操作身份及请求内容。
    public func mutateContact(peer: String, action: ContactAction, revision: Int64, operationID: UUID,
                              remark: String = "", message: String = "", requestID: String = "") async throws -> ChatContact {
        try await mutateContact(bytes: Self.contactMutation(peer: peer, action: action, revision: revision,
            operationID: operationID, remark: remark, message: message, requestID: requestID))
    }
    /// 以指定操作身份解析或创建与对方的私聊会话，返回服务端会话快照。
    public func resolve(peer: String, operationID: UUID) async throws -> ChatConversation {
        var input = IMResolveRequest()
        input.peerUserID = peer
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/conversations/resolve", input, as: IMConversation.self, id: operationID, map: ChatConversation.init)
    }
    /// 以指定标题、成员和操作身份创建群会话；权限及成员合法性由服务端校验。
    public func createGroup(title: String, members: [String], operationID: UUID) async throws -> ChatConversation {
        var input = IMCreateGroupRequest()
        input.title = title
        input.memberUserIds = members
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/groups/create", input, as: IMConversation.self, id: operationID, map: ChatConversation.init)
    }
    /// 按预期版本提交群操作；重复请求须复用 operationID 和原始字段。
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
    /// 读取指定会话的当前权威快照。
    public func conversation(_ id: String) async throws -> ChatConversation {
        var input = IMConversationRequest()
        input.conversationID = id
        return try await call("v1/im/conversations/get", input, as: IMConversation.self, map: ChatConversation.init)
    }
    /// 获取联系人和会话快照的一页；首次 token、cursor 为空，后续复用返回的快照 token 和游标。
    public func snapshot(token: String = "", cursor: String = "") async throws -> ChatSnapshot {
        var input = IMSnapshotRequest()
        input.snapshotToken = token
        input.cursor = cursor
        return try await call("v1/im/snapshot", input, as: IMSnapshotResponse.self, map: ChatSnapshot.init)
    }
    /// 按已提交游标及服务端 epoch 拉取一页增量，不自动提交本地检查点。
    public func events(cursor: String, epoch: String) async throws -> ChatEvents {
        var input = IMEventsRequest()
        input.cursor = cursor
        input.epoch = epoch
        return try await call("v1/im/events", input, as: IMEventsResponse.self, map: ChatEvents.init)
    }
    /// 读取会话历史的一页，将分页序列上界及边界版本原样发送至服务端。
    ///
    /// - Parameters:
    ///   - conversation: 目标会话身份。
    ///   - before: 排他性的向前分页序列，0 表示由服务端选择起点。
    ///   - upper: 本轮历史窗口的序列上界，0 表示请求服务端确定。
    ///   - boundary: 已知成员可见边界版本，0 表示尚未固定。
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
    /// 提交消息快照并返回权威消息；复用全部身份字段进行重试，不在此处写入本地 outbox。
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
    /// 提交指定消息的撤回动作并返回权威撤回快照；不自动清理本地恢复内容。
    public func revoke(conversation: String, message: String, operationID: UUID) async throws -> ChatMessage {
        var input = IMRevokeRequest()
        input.conversationID = conversation
        input.messageUuid = message
        input.operationID = operationID.uuidString.lowercased()
        return try await call(
            "v1/im/messages/revoke", input, as: IMMessage.self, id: operationID, map: ChatMessage.init)
    }
    /// 提交指定序列的已读或送达水位并返回会话快照；read 为 true 时提交已读。
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
    /// 读取消息回执快照的一页；后续分页复用 token 和 cursor，方法本身不合并页。
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
public enum ContactAction: String, Codable, Sendable { case request, accept, reject, cancel, delete, restore, remark, block, unblock }
public enum GroupAction: String, Codable, Sendable { case rename, add, remove, leave, transfer, dissolve }
/// 可保存到加密 outbox 的不可变消息身份；同一条消息的网络重试复用所有字段。
public struct ChatOutgoing: Codable, Sendable, Equatable {
    /// 消息自身的稳定 UUID；重试时不得重新生成。
    public let id: UUID
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    public let clientID: UUID
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    public let operationID: UUID
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    public let deviceID: UUID
    /// 所属聊天会话的稳定身份。
    public let conversationID: String
    /// 拟发送的内容类型，默认 text。
    public let kind: String
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    public let text: String
    /// 待发送的服务端媒体资产身份，保留编辑器顺序，默认空数组。
    public let assets: [String]
    /// 有序语义格式片段，默认 nil；发送时 nil 编码为空列表。
    public let textRuns: [ChatTextRun]?
    /// 链接原文；nil 表示没有附带链接。
    public let linkURL: String?
    /// 保存待发内容及全部发送身份；未提供身份时分别生成 UUID，默认发送空文字且无附件。
    ///
    /// 恢复或重试必须显式传回原身份，不应通过默认值创建同一消息的重试副本。
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
