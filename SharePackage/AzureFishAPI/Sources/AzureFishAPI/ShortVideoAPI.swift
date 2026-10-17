import AzureFishProtocol
import Foundation

/// Pixabay 素材与 AzureFish 内的互动快照；所有地址均来自服务端校验后的内容源。
public struct ShortVideoItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var author: String
    public var tags: String
    public var sourceURL: String
    public var videoURL: String
    public var thumbnailURL: String
    public var bytes: Int64
    public var duration: Int32
    public var width: Int32
    public var height: Int32
    public var liked: Bool
    public var likeCount: Int64
    public var commentCount: Int64
    public init(id: String, author: String, tags: String, sourceURL: String, videoURL: String, thumbnailURL: String,
                bytes: Int64, duration: Int32, width: Int32, height: Int32, liked: Bool = false, likeCount: Int64 = 0, commentCount: Int64 = 0) {
        self.id = id; self.author = author; self.tags = tags; self.sourceURL = sourceURL; self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL; self.bytes = bytes; self.duration = duration; self.width = width; self.height = height
        self.liked = liked; self.likeCount = likeCount; self.commentCount = commentCount
    }
    init(_ value: ShortVideo) {
        self.init(id: value.videoID, author: value.author, tags: value.tags, sourceURL: value.sourceURL, videoURL: value.videoURL,
                  thumbnailURL: value.thumbnailURL, bytes: value.byteCount, duration: value.durationSeconds, width: value.width, height: value.height,
                  liked: value.liked, likeCount: value.likeCount, commentCount: value.commentCount)
    }
}
public struct ShortVideoPage: Sendable {
    public let videos: [ShortVideoItem]
    public let cursor: String
    public let hasMore: Bool
    public init(videos: [ShortVideoItem], cursor: String, hasMore: Bool) { self.videos = videos; self.cursor = cursor; self.hasMore = hasMore }
}
public struct VideoComment: Sendable, Equatable, Identifiable {
    public let id: String
    public let author: ChatUser
    public let text: String
    public let createdAt: Int64
    public init(id: String, author: ChatUser, text: String, createdAt: Int64) { self.id = id; self.author = author; self.text = text; self.createdAt = createdAt }
    init(_ value: ShortVideoComment) { id = value.commentID; author = ChatUser(value.author); text = value.text; createdAt = value.createdAtMs }
}
public struct VideoCommentsPage: Sendable {
    public let comments: [VideoComment]
    public let cursor: String
    public let hasMore: Bool
    public init(comments: [VideoComment], cursor: String, hasMore: Bool) { self.comments = comments; self.cursor = cursor; self.hasMore = hasMore }
}
/// 短视频请求沿用现有会话刷新、错误封装及 Protobuf 传输。
public protocol ShortVideoServing: Sendable {
    func list(cursor: String) async throws -> ShortVideoPage
    func get(_ id: String) async throws -> ShortVideoItem
    func like(_ id: String, liked: Bool, operation: UUID) async throws -> ShortVideoItem
    func comments(_ id: String, cursor: String) async throws -> VideoCommentsPage
    func comment(_ video: String, id: UUID, text: String, operation: UUID) async throws -> ShortVideoItem
    func deleteComment(_ video: String, id: String, operation: UUID) async throws -> ShortVideoItem
}

public struct ShortVideoAPI: ShortVideoServing {
    private let im: IMAPI
    public init(session: APISessionManager) { im = IMAPI(session: session) }
    public func list(cursor: String = "") async throws -> ShortVideoPage {
        var input = ShortVideoListRequest(); input.cursor = cursor
        return try await im.call("v1/short-videos/list", input, as: ShortVideoListResponse.self) {
            ShortVideoPage(videos: $0.videos.map(ShortVideoItem.init), cursor: $0.nextCursor, hasMore: $0.hasMore_p)
        }
    }
    public func get(_ id: String) async throws -> ShortVideoItem {
        var input = ShortVideoIdentity(); input.videoID = id
        return try await im.call("v1/short-videos/get", input, as: ShortVideo.self, map: ShortVideoItem.init)
    }
    /// 设置目标状态；再次手动重试须复用 operation 和 liked。
    public func like(_ id: String, liked: Bool, operation: UUID) async throws -> ShortVideoItem {
        var input = ShortVideoLikeRequest(); input.videoID = id; input.liked = liked; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/short-videos/like", input, as: ShortVideo.self, id: operation, map: ShortVideoItem.init)
    }
    public func comments(_ id: String, cursor: String = "") async throws -> VideoCommentsPage {
        var input = ShortVideoCommentsRequest(); input.videoID = id; input.cursor = cursor
        return try await im.call("v1/short-videos/comments/list", input, as: ShortVideoCommentsResponse.self) {
            VideoCommentsPage(comments: $0.comments.map(VideoComment.init), cursor: $0.nextCursor, hasMore: $0.hasMore_p)
        }
    }
    /// 创建一级评论；正文不超过 500 字符，重试保留评论及操作身份。
    public func comment(_ video: String, id: UUID, text: String, operation: UUID) async throws -> ShortVideoItem {
        var input = ShortVideoCommentRequest(); input.videoID = video; input.commentID = id.uuidString.lowercased()
        input.text = text; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/short-videos/comments/create", input, as: ShortVideo.self, id: operation, map: ShortVideoItem.init)
    }
    public func deleteComment(_ video: String, id: String, operation: UUID) async throws -> ShortVideoItem {
        var input = ShortVideoDeleteCommentRequest(); input.videoID = video; input.commentID = id; input.operationID = operation.uuidString.lowercased()
        return try await im.call("v1/short-videos/comments/delete", input, as: ShortVideo.self, id: operation, map: ShortVideoItem.init)
    }
}
