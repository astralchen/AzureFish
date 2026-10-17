import Fluent
import Foundation

/// 素材与上游页缓存的认证加密载荷；缓存身份不包含 API Key。
final class ShortVideoCacheRecord: Model, @unchecked Sendable {
    static let schema = "short_video_cache"
    @ID(custom: "id", generatedBy: .user) var id: String?
    @Field(key: "payload") var payload: String
    init() {}
}
/// 每个账号、素材仅保留一个点赞身份。
final class ShortVideoLikeRecord: Model, @unchecked Sendable {
    static let schema = "short_video_likes"
    @ID(custom: "id", generatedBy: .user) var id: String?
    @Field(key: "video_id") var videoID: String
    @Field(key: "user_id") var userID: UUID
    init() {}
}
/// 一级评论；删除后清空正文，保留身份和摘要以拒绝旧创建请求复活。
final class ShortVideoCommentRecord: Model, @unchecked Sendable {
    static let schema = "short_video_comments"
    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "video_id") var videoID: String
    @Field(key: "user_id") var userID: UUID
    @Field(key: "sequence") var sequence: Int64
    @Field(key: "deleted") var deleted: Bool
    @Field(key: "payload") var payload: String
    init() {}
}
struct ShortVideoCommentState: Codable { var text: String; var created: Int64; var fingerprint: String }
struct CreateShortVideoSchema: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ShortVideoCacheRecord.schema).field("id", .string, .identifier(auto: false)).field("payload", .string, .required).create()
        try await db.schema(ShortVideoLikeRecord.schema).field("id", .string, .identifier(auto: false))
            .field("video_id", .string, .required).field("user_id", .uuid, .required, .references("users", "id"))
            .unique(on: "video_id", "user_id").create()
        try await db.schema(ShortVideoCommentRecord.schema).field("id", .uuid, .identifier(auto: false))
            .field("video_id", .string, .required).field("user_id", .uuid, .required, .references("users", "id"))
            .field("sequence", .int64, .required).field("deleted", .bool, .required).field("payload", .string, .required).create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(ShortVideoCommentRecord.schema).delete()
        try await db.schema(ShortVideoLikeRecord.schema).delete()
        try await db.schema(ShortVideoCacheRecord.schema).delete()
    }
}
