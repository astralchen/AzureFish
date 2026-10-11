import Fluent
import Foundation
import SQLKit

/// 正文、图片描述及互动均保存在认证加密 payload，索引仅保存身份和排序字段。
final class MomentRecord: Model, @unchecked Sendable {
    static let schema = "moments_posts"
    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "sequence") var sequence: Int64
    @Field(key: "payload") var payload: String
    init() {}
}
/// 以相册所有者 ID 为主键，保存经过认证加密的封面及版本快照。
final class MomentAlbumRecord: Model, @unchecked Sendable {
    static let schema = "moments_albums"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "payload") var payload: String
    init() {}
}
/// 连接资产与动态或相册的引用，供下载授权和垃圾回收共同检查。
final class MomentMediaReference: Model, @unchecked Sendable {
    static let schema = "moments_media_references"
    @ID(key: .id) var id: UUID?
    @Field(key: "asset_id") var assetID: UUID
    @Field(key: "target_id") var targetID: UUID
    @Field(key: "purpose") var purpose: String
    init() {}
}
/// 动态加密载荷，包含协议快照及防止重复发布、重复评论的请求摘要。
struct MomentState: Codable {
    var envelope: Data
    /// 发布内容摘要；删除动态后仍保留，防止同一动态 ID 被另一份内容复用。
    var fingerprint: String
    // 删除评论后仍保留请求摘要，旧请求不能重新插入已删除评论。
    var commentFingerprints: [String: String] = [:]
}
/// 创建朋友圈表，并将媒体资产扩展为带用途、可无聊天会话归属的记录。
struct CreateMomentsSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.transaction { db in
            try await db.schema(MomentRecord.schema).id()
                .field("owner_id", .uuid, .required, .references("users", "id"))
                .field("sequence", .int64, .required).unique(on: "sequence")
                .field("payload", .string, .required).create()
            try await db.schema(MomentAlbumRecord.schema).field("id", .uuid, .identifier(auto: false))
                .field("payload", .string, .required).create()
            try await db.schema(MomentMediaReference.schema).id()
                .field("asset_id", .uuid, .required, .references("media_assets", "id"))
                .field("target_id", .uuid, .required).field("purpose", .string, .required)
                .unique(on: "asset_id", "target_id", "purpose").create()
            // SQLite 不支持直接移除 NOT NULL；在延迟外键检查的事务内重建原表。
            guard let sql = db as? any SQLDatabase else { throw ConfigurationError.invalidDataDirectory }
            try await sql.raw("PRAGMA defer_foreign_keys = ON").run()
            try await sql.raw("""
                CREATE TABLE media_assets_moments (id UUID PRIMARY KEY NOT NULL,
                owner_id UUID NOT NULL REFERENCES users(id), conversation_id UUID REFERENCES im_conversations(id),
                state TEXT NOT NULL, expires_at BIGINT NOT NULL, reserved_bytes BIGINT NOT NULL,
                generation BIGINT NOT NULL, payload TEXT NOT NULL, purpose TEXT NOT NULL DEFAULT 'chat')
                """).run()
            try await sql.raw("""
                INSERT INTO media_assets_moments (id, owner_id, conversation_id, state, expires_at, reserved_bytes, generation, payload)
                SELECT id, owner_id, conversation_id, state, expires_at, reserved_bytes, generation, payload FROM media_assets
                """).run()
            try await sql.raw("DROP TABLE media_assets").run()
            try await sql.raw("ALTER TABLE media_assets_moments RENAME TO media_assets").run()
            guard try await sql.raw("PRAGMA foreign_key_check").all().isEmpty else { throw ConfigurationError.invalidDataDirectory }
            // SQLite 的延迟计数仍包含已被替换的旧表；完整校验后清除此事务的计数。
            try await sql.raw("PRAGMA defer_foreign_keys = OFF").run()
        }
    }
    func revert(on db: any Database) async throws {
        // 已发布朋友圈资产不能无损转为聊天资产，禁止破坏性降级。
        throw ConfigurationError.invalidDataDirectory
    }
}
