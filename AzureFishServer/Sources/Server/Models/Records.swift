import Fluent
import Foundation

// Fluent 的可变模型仅在 DatabaseGate 持有期间访问，不跨请求共享实例。
final class UserRecord: Model, @unchecked Sendable {
    static let schema = "users"
    @ID(key: .id) var id: UUID?
    @Field(key: "account_digest") var accountDigest: String
    @Field(key: "payload") var payload: String
    @Field(key: "version") var version: Int64
    init() {}
    init(id: UUID, accountDigest: String, payload: String, version: Int64) {
        self.id = id; self.accountDigest = accountDigest; self.payload = payload; self.version = version
    }
}

struct UserPayload: Codable, Sendable {
    var accountName: String
    var passwordHash: String
    var nickname: String
    var bio: String
    var createdAt: Int64
    var updatedAt: Int64
}

final class SessionRecord: Model, @unchecked Sendable {
    static let schema = "sessions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "device_id") var deviceID: String
    @Field(key: "access_digest") var accessDigest: String
    @Field(key: "refresh_digest") var refreshDigest: String
    @Field(key: "access_expiry") var accessExpiry: Int64
    @Field(key: "refresh_expiry") var refreshExpiry: Int64
    @Field(key: "generation") var generation: Int64
    @Field(key: "revoked") var revoked: Bool
    init() {}
}

final class OperationRecord: Model, @unchecked Sendable {
    static let schema = "operations"
    @ID(key: .id) var id: UUID?
    @Field(key: "scope") var scope: String
    @Field(key: "fingerprint") var fingerprint: String
    @Field(key: "session_id") var sessionID: UUID
    @Field(key: "generation") var generation: Int64
    @Field(key: "result") var result: String
    @Field(key: "result_expiry") var resultExpiry: Int64
    @Field(key: "retention_expiry") var retentionExpiry: Int64
    init() {}
}

final class UsedRefreshRecord: Model, @unchecked Sendable {
    static let schema = "used_refresh_tokens"
    @ID(key: .id) var id: UUID?
    @Field(key: "digest") var digest: String
    @Field(key: "session_id") var sessionID: UUID
    @Field(key: "expires_at") var expiresAt: Int64
    init() {}
}

final class MetadataRecord: Model, @unchecked Sendable {
    static let schema = "metadata"
    @ID(custom: "id", generatedBy: .user) var id: String?
    @Field(key: "value") var value: String
    init() {}
}

struct CreateSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("users").id()
            .field("account_digest", .string, .required).unique(on: "account_digest")
            .field("payload", .string, .required).field("version", .int64, .required).create()
        try await db.schema("sessions").id()
            .field("user_id", .uuid, .required, .references("users", "id"))
            .field("device_id", .string, .required)
            .field("access_digest", .string, .required).unique(on: "access_digest")
            .field("refresh_digest", .string, .required).unique(on: "refresh_digest")
            .field("access_expiry", .int64, .required).field("refresh_expiry", .int64, .required)
            .field("generation", .int64, .required).field("revoked", .bool, .required).create()
        try await db.schema("operations").id()
            .field("scope", .string, .required).field("fingerprint", .string, .required)
            .field("session_id", .uuid, .required, .references("sessions", "id"))
            .field("generation", .int64, .required).field("result", .string, .required)
            .field("result_expiry", .int64, .required).field("retention_expiry", .int64, .required).create()
        try await db.schema("used_refresh_tokens").id()
            .field("digest", .string, .required).unique(on: "digest")
            .field("session_id", .uuid, .required, .references("sessions", "id"))
            .field("expires_at", .int64, .required).create()
        try await db.schema("metadata").field("id", .string, .identifier(auto: false))
            .field("value", .string, .required).create()
    }
    func revert(on db: any Database) async throws {
        for name in ["metadata", "used_refresh_tokens", "operations", "sessions", "users"] {
            try await db.schema(name).delete()
        }
    }
}
