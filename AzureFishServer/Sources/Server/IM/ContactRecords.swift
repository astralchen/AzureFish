import Fluent
import Foundation
import Vapor

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
struct ContactSide: Codable, Sendable {
    var retained: Bool
    var remark: String = ""
    var blocked: Bool = false
    var revision: Int64
    var updated: Int64?
}
struct ContactState: Codable, Sendable {
    var status: String
    var requester: UUID
    var revision: Int64
    var updated: Int64
    // 可选字段允许原加密 payload 无损读取；读取时生成确定性的旧关系投影。
    var sides: [String: ContactSide]?
    var requestID: String?
    var requestStatus: String?
    var requestMessage: String?
    var requestUpdated: Int64?
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

/// 将旧共享关系升级为双方独立投影；同事务写入同步事件，不清理既有消息或凭据。
struct UpgradeContactSides: AsyncMigration {
    let crypto: Cryptography
    func prepare(on database: any Database) async throws {
        try await database.transaction { db in
            for row in try await ContactRecord.query(on: db).all() {
                let context = "contact:" + (try row.requireID()).uuidString
                var state = try JSONDecoder().decode(ContactState.self, from: crypto.open(row.payload, context: context))
                guard state.sides == nil else { continue }
                state.revision += 1
                state.sides = Dictionary(uniqueKeysWithValues: [row.firstUser, row.secondUser].map {
                    ($0.uuidString, ContactSide(retained: state.status == "friend", revision: state.revision, updated: state.updated))
                })
                state.requestID = try row.requireID().uuidString.lowercased()
                state.requestStatus = ["friend", "deleted"].contains(state.status) ? "accepted" : state.status
                state.requestMessage = ""; state.requestUpdated = state.updated
                row.payload = try crypto.seal(JSONEncoder().encode(state), context: context)
                try await row.save(on: db)
                for (user, peer) in [(row.firstUser, row.secondUser), (row.secondUser, row.firstUser)] {
                    let messages = try await IMEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
                    let contacts = try await ContactEventRecord.query(on: db).filter(\.$userID == user).sort(\.$position, .descending).first()?.position ?? 0
                    let event = ContactEventRecord(); event.id = UUID(); event.userID = user; event.peerID = peer
                    event.position = max(messages, contacts) + 1; try await event.create(on: db)
                }
            }
        }
    }
    func revert(on db: any Database) async throws {
        // 单向关系产生后无法无损还原旧模型，禁止自动降级覆盖。
        throw Abort(.conflict, reason: "Contact relationship migration cannot be reversed")
    }
}
