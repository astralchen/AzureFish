import Fluent
import Foundation

/// 每个用户对保留一条加密关系及单调版本，包括已结束关系。
final class ContactRecord: Model, @unchecked Sendable {
    static let schema = "im_contacts"
    @ID(key: .id) var id: UUID?
    @Field(key: "pair_key") var pairKey: String
    @Field(key: "first_user") var firstUser: UUID
    @Field(key: "second_user") var secondUser: UUID
    @Field(key: "payload") var payload: String
    init() {}
}
/// 与消息事件共享账号位置，独立表避免改变旧消息事件的外键约束。
final class ContactEventRecord: Model, @unchecked Sendable {
    static let schema = "im_contact_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "position") var position: Int64
    @Field(key: "peer_id") var peerID: UUID
    init() {}
}
struct ContactState: Codable, Sendable {
    var status: String
    var requester: UUID
    var revision: Int64
    var updated: Int64
}
struct CreateContactsSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ContactRecord.schema).id()
            .field("pair_key", .string, .required).unique(on: "pair_key")
            .field("first_user", .uuid, .required, .references("users", "id"))
            .field("second_user", .uuid, .required, .references("users", "id"))
            .field("payload", .string, .required).create()
        try await db.schema(ContactEventRecord.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("peer_id", .uuid, .required, .references("users", "id"))
            .field("position", .int64, .required).unique(on: "user_id", "position").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ContactEventRecord.schema).delete()
        try await db.schema(ContactRecord.schema).delete()
    }
}
