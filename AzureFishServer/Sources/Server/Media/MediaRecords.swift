import Fluent
import Foundation

final class MediaAssetRecord: Model, @unchecked Sendable {
    static let schema = "media_assets"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "conversation_id") var conversationID: UUID
    @Field(key: "state") var state: String
    @Field(key: "expires_at") var expiresAt: Int64
    @Field(key: "reserved_bytes") var reservedBytes: Int64
    @Field(key: "generation") var generation: Int64
    @Field(key: "payload") var payload: String
    init() {}
}
final class MediaResourceRecord: Model, @unchecked Sendable {
    static let schema = "media_resources"
    @ID(key: .id) var id: UUID?
    @Field(key: "asset_id") var assetID: UUID
    @OptionalField(key: "upload_id") var uploadID: UUID?
    @OptionalField(key: "wrapped_key") var wrappedKey: String?
    @Field(key: "payload") var payload: String
    init() {}
}
final class MediaPartRecord: Model, @unchecked Sendable {
    static let schema = "media_parts"
    @ID(key: .id) var id: UUID?
    @Field(key: "resource_id") var resourceID: UUID
    @Field(key: "part_index") var index: Int
    @Field(key: "payload") var payload: String
    init() {}
}
final class MediaReferenceRecord: Model, @unchecked Sendable {
    static let schema = "media_message_references"
    @ID(key: .id) var id: UUID?
    @Field(key: "asset_id") var assetID: UUID
    @Field(key: "message_id") var messageID: UUID
    init() {}
}
final class MediaJobRecord: Model, @unchecked Sendable {
    static let schema = "media_jobs"
    @ID(key: .id) var id: UUID?
    @Field(key: "asset_id") var assetID: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "generation") var generation: Int64
    @Field(key: "due_at") var dueAt: Int64
    @Field(key: "state") var state: String
    init() {}
}
struct CreateMediaSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(MediaAssetRecord.schema).id()
            .field("owner_id", .uuid, .required, .references("users", "id"))
            .field("conversation_id", .uuid, .required, .references("im_conversations", "id"))
            .field("state", .string, .required).field("expires_at", .int64, .required)
            .field("reserved_bytes", .int64, .required).field("generation", .int64, .required)
            .field("payload", .string, .required).create()
        try await db.schema(MediaResourceRecord.schema).id()
            .field("asset_id", .uuid, .required, .references(MediaAssetRecord.schema, "id"))
            .field("upload_id", .uuid).unique(on: "upload_id")
            .field("wrapped_key", .string).field("payload", .string, .required).create()
        try await db.schema(MediaPartRecord.schema).id()
            .field("resource_id", .uuid, .required, .references(MediaResourceRecord.schema, "id"))
            .field("part_index", .int, .required).unique(on: "resource_id", "part_index")
            .field("payload", .string, .required).create()
        try await db.schema(MediaReferenceRecord.schema).id()
            .field("asset_id", .uuid, .required, .references(MediaAssetRecord.schema, "id"))
            .field("message_id", .uuid, .required, .references("im_messages", "id"))
            .unique(on: "asset_id", "message_id").create()
        try await db.schema(MediaJobRecord.schema).id()
            .field("asset_id", .uuid, .required, .references(MediaAssetRecord.schema, "id"))
            .field("kind", .string, .required).unique(on: "asset_id", "kind")
            .field("generation", .int64, .required).field("due_at", .int64, .required)
            .field("state", .string, .required).create()
    }
    func revert(on db: any Database) async throws {
        for schema in [MediaJobRecord.schema, MediaReferenceRecord.schema, MediaPartRecord.schema, MediaResourceRecord.schema, MediaAssetRecord.schema] {
            try await db.schema(schema).delete()
        }
    }
}
struct MediaAssetState: Codable, Sendable {
    var kind: String
    var failure: String = ""
    var wasPublished = false
    var metadata: Data? = nil
}
struct MediaResourceState: Codable, Sendable {
    var role: String
    var filename: String
    var mime: String
    var bytes: Int64
    var sha256: String
    var manifest: String? = nil
}
struct MediaChunk: Codable, Sendable, Equatable {
    var index: Int
    var bytes: Int
    var sha256: String
    var filename: String
}
struct MediaManifest: Codable, Sendable {
    var version = 1
    var bytes: Int64
    var sha256: String
    var chunks: [MediaChunk]
}
/// 文件 IO 所需的不可变值快照；不得把 Fluent 模型带出 gate。
struct MediaResourceTicket: Sendable {
    var id: UUID
    var asset: UUID
    var owner: UUID
    var generation: Int64
    var key: Data
    var state: MediaResourceState
}
struct MediaGrant: Codable, Sendable {
    var user: UUID
    var session: UUID
    var resource: UUID
    var asset: UUID
    var purpose: String
    var message: UUID?
    var generation: Int64
    var expires: Int64
}
struct MediaLimits: Sendable {
    static let chunk = 4 * 1024 * 1024
    static let previewBudget: Int64 = 8 * 1024 * 1024
    static let lifetime: Int64 = 24 * 60 * 60 * 1000
    var accountBytes: Int64 = 5 * 1024 * 1024 * 1024
    var instanceBytes: Int64 = 20 * 1024 * 1024 * 1024
    var accountConcurrency = 4
    var instanceConcurrency = 16
    var processingSeconds: Double = 120
    func maximum(kind: String, role: String) -> Int64 {
        if role == "paired_video" || kind == "video" || kind == "file" { return 512 * 1024 * 1024 }
        if kind == "audio" { return 20 * 1024 * 1024 }
        return 25 * 1024 * 1024
    }
}
