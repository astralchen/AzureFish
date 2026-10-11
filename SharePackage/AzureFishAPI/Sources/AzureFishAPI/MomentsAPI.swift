import AzureFishProtocol
import Foundation
import SwiftProtobuf

/// 朋友圈对当前查看者可见的完整动态快照；互动已在服务端过滤。
public struct MomentsPost: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var author: ChatUser
    public var text: String
    /// 视频动态的单个资产；图片或纯文本动态为 nil。
    public var video: ChatAsset?
    /// 按发布顺序排列的图片；与 video 互斥，纯文本动态为空。
    public var images: [ChatAsset]
    /// 自 Unix 纪元起的创建时间，单位为毫秒。
    public var createdAt: Int64
    /// 服务端分配的排序序号；列表按降序展示，不以设备时间排序。
    public var sequence: Int64
    public var revision: Int64
    /// 是否为已删除墓碑；发布对账可能返回此状态，列表不展示墓碑。
    public var deleted: Bool
    public var likes: [ChatUser]
    public var comments: [MomentsComment]
    public init(id: String, author: ChatUser, text: String, images: [ChatAsset] = [], video: ChatAsset? = nil, createdAt: Int64, sequence: Int64 = 0,
                revision: Int64 = 1, deleted: Bool = false, likes: [ChatUser] = [], comments: [MomentsComment] = []) {
        self.id = id; self.author = author; self.text = text; self.images = images; self.video = video; self.createdAt = createdAt
        self.sequence = sequence; self.revision = revision; self.deleted = deleted; self.likes = likes; self.comments = comments
    }
    init(_ value: MomentPost) {
        self.init(id: value.postID, author: ChatUser(value.author), text: value.text, images: value.images.map(ChatAsset.init), video: value.hasVideo ? ChatAsset(value.video) : nil,
                  createdAt: value.createdAtMs, sequence: value.sequence, revision: value.revision, deleted: value.deleted,
                  likes: value.likes.map(ChatUser.init), comments: value.comments.map(MomentsComment.init))
    }
}
/// 当前查看者可见的评论快照；replyTo 为 nil 时表示直接评论动态。
public struct MomentsComment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var author: ChatUser
    public var text: String
    public var replyTo: ChatUser?
    /// 自 Unix 纪元起的创建时间，单位为毫秒。
    public var createdAt: Int64
    public init(id: String, author: ChatUser, text: String, replyTo: ChatUser? = nil, createdAt: Int64) {
        self.id = id; self.author = author; self.text = text; self.replyTo = replyTo; self.createdAt = createdAt
    }
    init(_ value: MomentComment) {
        self.init(id: value.commentID, author: ChatUser(value.author), text: value.text,
                  replyTo: value.hasReplyTo ? ChatUser(value.replyTo) : nil, createdAt: value.createdAtMs)
    }
}
/// 相册所有者、可选封面及封面写入使用的版本快照。
public struct MomentsAlbum: Codable, Sendable, Equatable {
    public var owner: ChatUser
    public var cover: ChatAsset?
    public var revision: Int64
    public init(owner: ChatUser, cover: ChatAsset? = nil, revision: Int64 = 0) { self.owner = owner; self.cover = cover; self.revision = revision }
    init(_ value: MomentAlbum) { self.init(owner: ChatUser(value.owner), cover: value.hasCover ? ChatAsset(value.cover) : nil, revision: value.revision) }
}
/// 一页可见动态和续页信息；过滤删除记录后 posts 可以为空。
public struct MomentsPage: Sendable {
    public let posts: [MomentsPost]
    /// 服务端生成的不透明游标，仅可在相同账号与作者筛选下用于续页。
    public let cursor: String
    public let hasMore: Bool
}
/// 批量权限复核结果，区分当前可用快照与应从缓存移除的动态 ID。
public struct MomentsValidation: Sendable {
    public let posts: [MomentsPost]
    public let unavailable: [String]
}
/// 朋友圈请求复用账号刷新、环境隔离和 Protobuf 传输，页面不持有协议类型。
public struct MomentsAPI: Sendable {
    private let im: IMAPI
    public init(session: APISessionManager) { im = IMAPI(session: session) }
    /// 获取动态页；author 为空表示主动态流，cursor 为空表示开启新一轮分页。
    ///
    /// limit 默认 20，服务端允许的最大值为 50；续页应原样复用返回的游标。
    public func list(author: String = "", cursor: String = "", limit: Int32 = 20) async throws -> MomentsPage {
        var input = MomentsListRequest(); input.authorID = author; input.cursor = cursor; input.limit = limit
        return try await im.call("v1/moments/list", input, as: MomentsListResponse.self) {
            MomentsPage(posts: $0.posts.map(MomentsPost.init), cursor: $0.nextCursor, hasMore: $0.hasMore_p)
        }
    }
    /// 复核最多 100 个动态 ID；响应超限时递归拆分批次，单项仍超限则抛出错误。
    public func validate(_ ids: [String]) async throws -> MomentsValidation {
        var input = MomentsGetRequest(); input.postIds = ids
        do {
            return try await im.call("v1/moments/get", input, as: MomentsGetResponse.self) {
                MomentsValidation(posts: $0.posts.map(MomentsPost.init), unavailable: $0.unavailableIds)
            }
        } catch APIClientError.service(let failure) where failure.code == .payloadTooLarge && ids.count > 1 {
            let middle = ids.count / 2
            let left = try await validate(Array(ids[..<middle])), right = try await validate(Array(ids[middle...]))
            return MomentsValidation(posts: left.posts + right.posts, unavailable: left.unavailable + right.unavailable)
        }
    }
    /// 生成可保存在加密库中的发布原字节；重试须原样复用。
    public static func publication(id: UUID, operation: UUID, text: String, assets: [String], video: String? = nil) throws -> Data {
        var input = MomentPublishRequest(); input.postID = id.uuidString.lowercased(); input.operationID = operation.uuidString.lowercased()
        input.text = text; input.assetIds = assets; input.videoAssetID = video ?? ""; return try input.serializedData()
    }
    /// 发送已冻结的发布请求字节；调用方必须先持久化，并在重试时原样复用。
    public func publish(bytes: Data) async throws -> MomentsPost {
        let input = try MomentPublishRequest(serializedBytes: bytes)
        guard let id = UUID(uuidString: input.operationID), bytes.count <= 80 * 1024 else { throw APIClientError.invalidRequest }
        let credentials = try await im.session.credentials()
        var operation = AccountOperation<MomentsPost>(operationID: id, environment: im.session.environment,
            path: "v1/moments/publish", method: .post, body: bytes, expectedStatus: 200, authorization: SessionIdentity(credentials)) {
            MomentsPost(try MomentMutationResult(serializedBytes: $0).post)
        }
        operation.maximumResponseBytes = 4 * 1024 * 1024
        return try await im.session.execute(operation)
    }
    /// 查询当前账号自己的动态发布结果；已删除时仍可能返回墓碑。
    public func result(_ id: String) async throws -> MomentsPost {
        var input = MomentIdentityRequest(); input.postID = id
        return try await im.call("v1/moments/result", input, as: MomentPost.self, map: MomentsPost.init)
    }
    /// 删除自己的动态并返回当前墓碑；重试复用相同 operation。
    public func delete(_ id: String, operation: UUID) async throws -> MomentsPost {
        var input = MomentMutationRequest(); input.postID = id; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/moments/delete", input, as: MomentMutationResult.self, id: operation) { MomentsPost($0.post) }
    }
    /// 将点赞设置为 liked 指定的状态；重试须复用 operation 和目标状态。
    public func like(_ id: String, liked: Bool, operation: UUID) async throws -> MomentsPost {
        var input = MomentMutationRequest(); input.postID = id; input.operationID = operation.uuidString.lowercased(); input.liked = liked
        return try await im.call("v1/moments/like", input, as: MomentMutationResult.self, id: operation) { MomentsPost($0.post) }
    }
    /// 创建评论并返回动态快照；replyTo 为空表示直接评论，重试复用评论及操作 ID。
    public func comment(post: String, id: UUID, text: String, replyTo: String = "", operation: UUID) async throws -> MomentsPost {
        var input = MomentCommentRequest(); input.postID = post; input.commentID = id.uuidString.lowercased()
        input.operationID = operation.uuidString.lowercased(); input.text = text; input.replyToUserID = replyTo
        return try await im.call("v1/moments/comments/create", input, as: MomentMutationResult.self, id: operation) { MomentsPost($0.post) }
    }
    /// 删除自己的评论并返回动态快照；重试复用相同 operation。
    public func deleteComment(post: String, comment: String, operation: UUID) async throws -> MomentsPost {
        var input = MomentDeleteCommentRequest(); input.postID = post; input.commentID = comment; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/moments/comments/delete", input, as: MomentMutationResult.self, id: operation) { MomentsPost($0.post) }
    }
    /// 获取指定所有者的当前可见相册，权限以服务端当前关系为准。
    public func album(_ owner: String) async throws -> MomentsAlbum {
        var input = MomentAlbumRequest(); input.ownerID = owner
        return try await im.call("v1/moments/album", input, as: MomentAlbum.self, map: MomentsAlbum.init)
    }
    /// 按相册 revision 替换封面；asset 为空时清除封面，重试复用原版本和 operation。
    public func cover(asset: String, revision: Int64, operation: UUID) async throws -> MomentsAlbum {
        var input = MomentCoverRequest(); input.assetID = asset; input.expectedRevision = revision; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/moments/cover", input, as: MomentMutationResult.self, id: operation) { MomentsAlbum($0.album) }
    }
}
