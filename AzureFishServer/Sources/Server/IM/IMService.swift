import Fluent
import Foundation
import SwiftProtobuf
import Vapor

/// 提供单实例 IM 权威写入与可重放读取；所有数据访问复用账号事务锁。
final class IMService: Sendable {
    let accounts: AccountService
    let epoch: String
    let media: MediaService?
    let live: IMLiveCoordinator
    var crypto: Cryptography { accounts.crypto }
    init(accounts: AccountService, epoch: String, media: MediaService? = nil, live: IMLiveCoordinator? = nil) {
        self.accounts = accounts; self.epoch = epoch; self.media = media
        self.live = live ?? IMLiveCoordinator(accounts: accounts, epoch: epoch)
    }

    func register(on routes: any RoutesBuilder) {
        let im = routes.grouped("im")
        im.post("users", "lookup", use: lookup)
        im.post("contacts", "get", use: contactGet)
        im.post("contacts", "mutate", use: contactMutate)
        im.post("conversations", "resolve", use: resolve)
        im.post("groups", "create", use: createGroup)
        im.post("groups", "update", use: updateGroup)
        im.post("conversations", "get", use: conversation)
        im.on(.POST, "messages", "send", body: .collect(maxSize: "256kb"), use: send)
        im.post("messages", "revoke", use: revoke)
        im.post("read", use: markRead)
        im.post("delivered", use: markDelivered)
        im.post("history", use: history)
        im.post("events", use: events)
        im.post("snapshot", use: snapshot)
        im.post("receipts", use: receipts)
        registerLive(on: im)
    }

    /// 包装已自行组织事务的账号操作；仅成功返回后唤醒受影响在线账号。
    func committing<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let signals = IMCommitSignals()
        let result = try await IMCommitSignals.$current.withValue(signals, operation: body)
        await live.changed(signals.affected)
        return result
    }
    func read<M: Message & Sendable>(_ req: Request, _ body: @escaping @Sendable (SessionRecord, any Database) async throws -> M) async throws -> Response {
        let result = try await accounts.gate.run {
            try await req.db.transaction { db in
                let session = try await self.accounts.authenticate(req, db: db)
                return try await body(session, db)
            }
        }
        return try protobufResponse(result)
    }

    func write<M: Message & Sendable>(_ req: Request, operation: String, bytes: Data, name: String,
                                      _ body: @escaping @Sendable (SessionRecord, any Database) async throws -> M) async throws -> Response {
        let id = try Validation.uuid(operation, field: "operation_id")
        let signals = IMCommitSignals()
        let result = try await IMCommitSignals.$current.withValue(signals) {
            try await accounts.gate.run {
                try await req.db.transaction { db in
                    let session = try await self.accounts.authenticate(req, db: db)
                    try await self.accounts.limiter.check("im:" + session.userID.uuidString, limit: 120, now: self.accounts.clock())
                    let scope = "im:" + name + ":" + (try session.requireID()).uuidString
                    if let replay = try await self.accounts.replay(id, scope: scope, bytes: bytes, db: db) {
                        return try await self.materialize(replay, name: name, user: session.userID, db: db)
                    }
                    var result = try await body(session, db).serializedData()
                    if name == "send" || name == "revoke" {
                        let message = try IMMessage(serializedBytes: result)
                        var identity = IMMessage(); identity.conversationID = message.conversationID; identity.messageUuid = message.messageUuid
                        result = try identity.serializedData()
                    }
                    try await self.accounts.record(id, scope: scope, bytes: bytes, result: result, session: session, db: db)
                    return try await self.materialize(result, name: name, user: session.userID, db: db)
                }
            }
        }
        await live.changed(signals.affected)
        return Response(status: .ok, headers: ["Content-Type": "application/protobuf"], body: .init(data: result))
    }

    // 幂等记录只保存消息身份，撤回后任何旧发送重试都不能恢复正文。
    private func materialize(_ bytes: Data, name: String, user: UUID, db: any Database) async throws -> Data {
        if name == "contact" {
            let identity = try ContactRelationship(serializedBytes: bytes)
            return try await contactView(user: user, peer: Validation.uuid(identity.peer.userID, field: "peer_user_id"), db: db).serializedData()
        }
        guard name == "send" || name == "revoke" else { return bytes }
        let identity = try IMMessage(serializedBytes: bytes)
        let (conversation, state) = try await load(identity.conversationID, user: user, db: db)
        let row = try await visibleMessage(Validation.uuid(identity.messageUuid, field: "message_uuid"), conversation: conversation.requireID(), state: state, user: user, db: db)
        return try renderedMessage(row, state).serializedData()
    }

    func load(_ id: String, user: UUID, db: any Database, active: Bool = false) async throws -> (IMConversationRecord, IMConversationState) {
        let uuid = try Validation.uuid(id, field: "conversation_id")
        guard let row = try await IMConversationRecord.find(uuid, on: db) else { throw APIError(.notFound, "CONVERSATION_NOT_FOUND") }
        var state: IMConversationState = try decrypt(row.payload, context: "conversation:" + uuid.uuidString)
        guard let member = state.members.first(where: { $0.user == user }) else { throw APIError(.notFound, "CONVERSATION_NOT_FOUND") }
        if active && (!member.active || state.dissolved) { throw APIError(.forbidden, "CONVERSATION_CLOSED") }
        try await ensureUnread(row, state: &state, db: db)
        return (row, state)
    }
    func save(_ row: IMConversationRecord, _ state: IMConversationState, db: any Database) async throws {
        row.payload = try encrypt(state, context: "conversation:" + row.requireID().uuidString)
        try await row.save(on: db)
    }
    func encrypt<T: Encodable>(_ value: T, context: String) throws -> String { try crypto.seal(JSONEncoder().encode(value), context: context) }
    func decrypt<T: Decodable>(_ value: String, context: String) throws -> T { try JSONDecoder().decode(T.self, from: crypto.open(value, context: context)) }
    func messageState(_ row: IMMessageRecord) throws -> IMMessageState { try decrypt(row.payload, context: "message:" + row.requireID().uuidString) }
    func storedMessage(_ row: IMMessageRecord) throws -> IMMessage { try IMMessage(serializedBytes: messageState(row).envelope) }
    func limit(_ value: Int32, max: Int, default fallback: Int) throws -> Int {
        guard value >= 0, value <= max else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "limit") }
        return value == 0 ? fallback : Int(value)
    }
    func cursor(user: UUID, resource: String, position: Int64) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(IMCursor(user: user, resource: resource, epoch: epoch, position: position))
        return data.base64EncodedString() + "." + crypto.digest(data, purpose: "im-cursor")
    }
    func position(_ token: String, user: UUID, resource: String) throws -> Int64 {
        if token.isEmpty { return 0 }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 2048, parts.count == 2, let bytes = Data(base64Encoded: String(parts[0])),
              crypto.digest(bytes, purpose: "im-cursor") == parts[1],
              let value = try? JSONDecoder().decode(IMCursor.self, from: bytes), value.user == user,
              value.resource == resource, value.position >= 0 else { throw APIError(.badRequest, "INVALID_CURSOR") }
        guard value.epoch == epoch else { throw APIError(.conflict, "CURSOR_EXPIRED") }
        return value.position
    }
    func tail(_ user: UUID, db: any Database) async throws -> Int64 {
        let messages = try await IMEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
        let contacts = try await ContactEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
        return max(messages, contacts)
    }
    func emit(_ conversation: UUID, users: [UUID], kind: String, message: UUID? = nil, db: any Database) async throws {
        IMCommitSignals.current?.insert(users)
        for user in Set(users) {
            let event = IMEventRecord()
            event.id = UUID(); event.userID = user; event.position = try await tail(user, db: db) + 1
            event.conversationID = conversation; event.messageID = message; event.kind = kind
            try await event.create(on: db)
        }
    }
    func view(_ row: IMConversationRecord, _ state: IMConversationState, user: UUID, db: any Database) async throws -> IMConversation {
        guard let member = state.members.first(where: { $0.user == user }) else { throw APIError(.notFound, "CONVERSATION_NOT_FOUND") }
        var result = IMConversation()
        result.conversationID = try row.requireID().uuidString.lowercased(); result.kind = state.kind; result.title = state.title
        result.ownerUserID = state.owner?.uuidString.lowercased() ?? ""
        result.serverRevision = state.revision; result.boundaryRevision = state.boundary
        result.latestSeq = member.upperBound(state.latest); result.closed = !member.active || state.dissolved
        var state = state
        try await ensureUnread(row, state: &state, db: db)
        let memberIDs = state.members.map(\.user)
        let profiles = try await UserRecord.query(on: db).filter(\.$id ~~ memberIDs).all()
        let users = Dictionary(uniqueKeysWithValues: try profiles.map { (try $0.requireID(), $0) })
        for value in state.members {
            var m = IMMember(); m.userID = value.user.uuidString.lowercased(); m.active = value.active
            m.intervals = value.intervals.map { interval in
                var i = IMMembershipInterval(); i.joinedSeq = interval.joined; i.leftSeq = interval.left; return i
            }
            if let userRow = users[value.user] {
                let payload = try accounts.payload(userRow)
                m.profile.userID = m.userID; m.profile.nickname = payload.nickname
                m.profile.profileVersion = userRow.version
                m.profile.avatarID = payload.avatarID ?? ""
                m.profile.deleted = payload.deleted == true
            }
            result.members.append(m)
        }
        var read = IMReadState(); read.readThroughSeq = member.read; read.deliveredThroughSeq = member.delivered
        read.summaryAtSeq = result.latestSeq; read.serverRevision = state.summaryRevision
        read.unreadCount = state.members.first { $0.user == user }?.unread?.count ?? 0
        for interval in member.intervals.reversed() {
            let upper = min(result.latestSeq, interval.left == 0 ? result.latestSeq : interval.left - 1)
            if let latest = try await IMMessageRecord.query(on: db)
                .filter(\.$conversationID == row.requireID()).filter(\.$sequence >= interval.joined)
                .filter(\.$sequence <= upper).sort(\.$sequence, .descending).first() {
                result.latestMessage = try renderedMessage(latest, state)
                break
            }
        }
        if let frozen = member.closedConversation {
            result = try IMConversation(serializedBytes: frozen)
        }
        result.readState = read; return result
    }
    func renderedMessage(_ row: IMMessageRecord, _ state: IMConversationState) throws -> IMMessage {
        let stored = try messageState(row)
        var message = try IMMessage(serializedBytes: stored.envelope)
        if message.contentType == "system" { message.clearReceipt(); return message }
        var summary = IMReceiptSummary(); summary.audienceVersion = 1; summary.serverRevision = state.summaryRevision
        summary.expectedCount = Int64(stored.audience.count)
        for user in stored.audience {
            if let member = state.members.first(where: { $0.user == user }) {
                if member.delivered >= row.sequence { summary.deliveredCount += 1 }
                if member.read >= row.sequence { summary.readCount += 1 }
            }
        }
        message.receipt = summary; return message
    }
}
