import Fluent
import Foundation

// 可变模型仅在账号服务共享 gate 和事务内使用。
final class IMConversationRecord: Model, @unchecked Sendable {
    static let schema = "im_conversations"
    @ID(key: .id) var id: UUID?
    @Field(key: "pair_key") var pairKey: String
    @Field(key: "payload") var payload: String
    init() {}
}
final class IMMemberRecord: Model, @unchecked Sendable {
    static let schema = "im_members"
    @ID(key: .id) var id: UUID?
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "user_id") var userID: UUID
    init() {}
}
final class IMMessageRecord: Model, @unchecked Sendable {
    static let schema = "im_messages"
    @ID(key: .id) var id: UUID?
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "sequence") var sequence: Int64
    @Field(key: "client_key") var clientKey: String
    @Field(key: "payload") var payload: String
    init() {}
}
final class IMEventRecord: Model, @unchecked Sendable {
    static let schema = "im_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "position") var position: Int64
    @Field(key: "conversation_id") var conversationID: UUID
    @OptionalField(key: "message_id") var messageID: UUID?
    @Field(key: "kind") var kind: String
    init() {}
}
final class IMSnapshotRecord: Model, @unchecked Sendable {
    static let schema = "im_snapshots"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "resource") var resource: String
    @Field(key: "expires_at") var expiresAt: Int64
    @Field(key: "payload") var payload: String
    init() {}
}

struct CreateIMSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(IMConversationRecord.schema).id()
            .field("pair_key", .string, .required).unique(on: "pair_key")
            .field("payload", .string, .required).create()
        try await db.schema(IMMemberRecord.schema).id()
            .field("conversation_id", .uuid, .required, .references(IMConversationRecord.schema, "id"))
            .field("user_id", .uuid, .required, .references("users", "id"))
            .unique(on: "user_id", "conversation_id").create()
        try await db.schema(IMMessageRecord.schema).id()
            .field("conversation_id", .uuid, .required, .references(IMConversationRecord.schema, "id"))
            .field("sequence", .int64, .required).unique(on: "conversation_id", "sequence")
            .field("client_key", .string, .required).unique(on: "client_key")
            .field("payload", .string, .required).create()
        try await db.schema(IMEventRecord.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("position", .int64, .required).unique(on: "user_id", "position")
            .field("conversation_id", .uuid, .required, .references(IMConversationRecord.schema, "id"))
            .field("message_id", .uuid, .references(IMMessageRecord.schema, "id"))
            .field("kind", .string, .required).create()
        try await db.schema(IMSnapshotRecord.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("resource", .string, .required).field("expires_at", .int64, .required)
            .field("payload", .string, .required).create()
    }
    func revert(on db: any Database) async throws {
        for name in [IMSnapshotRecord.schema, IMEventRecord.schema, IMMessageRecord.schema, IMMemberRecord.schema, IMConversationRecord.schema] {
            try await db.schema(name).delete()
        }
    }
}

struct IMIntervalState: Codable, Sendable {
    var joined: Int64
    var left: Int64 = 0
}
/// 仅持久化在加密会话 payload 内；缺失或未知版本在同事务重建。
struct IMUnreadProjection: Codable, Sendable {
    var version: Int = 1
    var count: Int64 = 0
}
struct IMMemberState: Codable, Sendable {
    var user: UUID
    var intervals: [IMIntervalState]
    var read: Int64 = 0
    var delivered: Int64 = 0
    var closedConversation: Data? = nil
    var unread: IMUnreadProjection? = .init()
    var active: Bool { intervals.last?.left == 0 }
    func upperBound(_ latest: Int64) -> Int64 { active ? latest : (intervals.last?.left ?? 1) - 1 }
    func sees(_ seq: Int64) -> Bool { intervals.contains { seq >= $0.joined && ($0.left == 0 || seq < $0.left) } }
}
struct IMConversationState: Codable, Sendable {
    var kind: String
    var title: String
    var owner: UUID?
    var members: [IMMemberState]
    var revision: Int64 = 1
    var boundary: Int64 = 1
    var summaryRevision: Int64 = 1
    var latest: Int64 = 0
    var dissolved: Bool = false
}
struct IMMessageState: Codable, Sendable {
    var envelope: Data
    var audience: [UUID]
    var fingerprint: String
}
struct IMCursor: Codable, Sendable {
    var user: UUID
    var resource: String
    var epoch: String
    var position: Int64
}
