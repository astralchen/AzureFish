import Fluent
import Foundation
import SwiftProtobuf
import Vapor

struct ShortVideoServiceKey: StorageKey { typealias Value = ShortVideoService }
/// 已登录账号共享公开视频；互动按查看者的拉黑关系过滤，不套用朋友圈好友规则。
final class ShortVideoService: Sendable {
    let im: IMService
    let provider: PixabayProvider
    init(im: IMService, provider: PixabayProvider) { self.im = im; self.provider = provider }
    func register(on routes: any RoutesBuilder) {
        let routes = routes.grouped("short-videos")
        routes.post("list", use: list); routes.post("get", use: get); routes.post("like", use: like)
        routes.post("comments", "list", use: comments)
        routes.post("comments", "create", use: comment); routes.post("comments", "delete", use: deleteComment)
    }
    func validate(_ id: String) throws {
        guard id.hasPrefix("pixabay:"), let value = Int64(id.dropFirst(8)), value > 0, id == "pixabay:\(value)" else {
            throw APIError(.badRequest, "VALIDATION_FAILED", field: "video_id")
        }
    }
    /// 在上游网络等待前验证身份；返回结果前再次认证，防止退出后继续返回数据。
    func list(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(ShortVideoListRequest.self, from: req)
        let page = try await im.accounts.gate.run {
            let session = try await self.im.accounts.authenticate(req, db: req.db)
            try await self.im.accounts.limiter.check("short-video-read:" + session.userID.uuidString, limit: 120, now: self.im.accounts.clock())
            return Int(try self.im.position(input.cursor, user: session.userID, resource: "short-videos")) + 1
        }
        let result = try await provider.page(page, db: req.db, crypto: im.crypto)
        return try await im.read(req) { session, db in
            var output = ShortVideoListResponse()
            var seen = Set<String>()
            for bytes in result.videos {
                let video = try ShortVideo(serializedBytes: bytes)
                guard seen.insert(video.videoID).inserted else { continue }
                let row = try await ShortVideoCacheRecord.find(video.videoID, on: db) ?? ShortVideoCacheRecord()
                row.id = video.videoID; row.payload = try self.im.crypto.seal(bytes, context: "short-video:" + video.videoID)
                try await row.save(on: db)
                output.videos.append(try await self.view(video, user: session.userID, db: db))
            }
            output.hasMore_p = result.hasMore
            if result.hasMore { output.nextCursor = try self.im.cursor(user: session.userID, resource: "short-videos", position: Int64(page)) }
            return output
        }
    }
    func load(_ id: String, db: any Database) async throws -> ShortVideo {
        try validate(id)
        guard let row = try await ShortVideoCacheRecord.find(id, on: db) else { throw APIError(.notFound, "SHORT_VIDEO_UNAVAILABLE") }
        return try ShortVideo(serializedBytes: im.crypto.open(row.payload, context: "short-video:" + id))
    }
    func visible(_ owner: UUID, user: UUID, db: any Database) async throws -> Bool {
        guard let record = try await UserRecord.find(owner, on: db), try im.accounts.payload(record).deleted != true else { return false }
        if owner == user { return true }
        guard let contact = try await im.contactRecord(user, owner, db: db) else { return true }
        let state = try im.contactState(contact)
        return !(state.sides?.values.contains(where: { $0.blocked }) ?? false)
    }
    func visibleComments(_ id: String, user: UUID, db: any Database) async throws -> [ShortVideoCommentRecord] {
        var result: [ShortVideoCommentRecord] = []
        for row in try await ShortVideoCommentRecord.query(on: db).filter(\.$videoID == id).filter(\.$deleted == false).sort(\.$sequence, .descending).all() {
            if try await visible(row.userID, user: user, db: db) { result.append(row) }
        }
        return result
    }
    func view(_ source: ShortVideo, user: UUID, db: any Database) async throws -> ShortVideo {
        var result = source
        result.liked = try await ShortVideoLikeRecord.find(source.videoID + ":" + user.uuidString, on: db) != nil
        result.likeCount = Int64(try await ShortVideoLikeRecord.query(on: db).filter(\.$videoID == source.videoID).count())
        result.commentCount = Int64(try await visibleComments(source.videoID, user: user, db: db).count)
        return result
    }
    func get(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(ShortVideoIdentity.self, from: req)
        return try await read(req) { session, db in try await self.view(self.load(input.videoID, db: db), user: session.userID, db: db) }
    }
    /// 详情与评论分页共用列表的账号读取限额，在查询和拉黑过滤前拒绝超额请求。
    private func read<M: Message & Sendable>(_ req: Request,
        _ body: @escaping @Sendable (SessionRecord, any Database) async throws -> M) async throws -> Response {
        try await im.read(req) { session, db in
            try await self.im.accounts.limiter.check("short-video-read:" + session.userID.uuidString, limit: 120, now: self.im.accounts.clock())
            return try await body(session, db)
        }
    }
    /// 幂等记录只保存视频身份，重放返回当前过滤后的互动状态。
    func write(_ req: Request, video: String, operation: String, bytes: Data, name: String,
               body: @escaping @Sendable (UUID, any Database) async throws -> Void) async throws -> Response {
        try validate(video)
        let operation = try Validation.uuid(operation, field: "operation_id")
        return try await im.read(req) { session, db in
            let source = try await self.load(video, db: db)
            let scope = "short-video:" + name + ":" + session.userID.uuidString
            try await self.im.accounts.limiter.check("short-video-write:" + session.userID.uuidString, limit: 120, now: self.im.accounts.clock())
            if let row = try await OperationRecord.find(operation, on: db) {
                guard row.scope == scope, row.fingerprint == self.im.crypto.digest(bytes, purpose: scope) else { throw APIError(.conflict, "OPERATION_CONFLICT") }
            } else {
                try await body(session.userID, db)
                var identity = ShortVideoIdentity(); identity.videoID = video
                try await self.im.accounts.record(operation, scope: scope, bytes: bytes, result: identity.serializedData(), session: session, db: db)
            }
            return try await self.view(source, user: session.userID, db: db)
        }
    }
    func like(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ShortVideoLikeRequest.self, from: req)
        return try await write(req, video: input.videoID, operation: input.operationID, bytes: bytes, name: "like") { user, db in
            let id = input.videoID + ":" + user.uuidString
            let old = try await ShortVideoLikeRecord.find(id, on: db)
            if input.liked, old == nil {
                let row = ShortVideoLikeRecord(); row.id = id; row.videoID = input.videoID; row.userID = user; try await row.create(on: db)
            } else if !input.liked { try await old?.delete(on: db) }
        }
    }
    func comments(_ req: Request) async throws -> Response {
        let (input, _) = try requestMessage(ShortVideoCommentsRequest.self, from: req)
        return try await read(req) { session, db in
            _ = try await self.load(input.videoID, db: db)
            let position = try self.im.position(input.cursor, user: session.userID, resource: "short-video-comments:" + input.videoID)
            let rows = try await self.visibleComments(input.videoID, user: session.userID, db: db).filter { position == 0 || $0.sequence < position }
            var output = ShortVideoCommentsResponse()
            for row in rows.prefix(20) {
                let id = try row.requireID()
                let state: ShortVideoCommentState = try self.im.decrypt(row.payload, context: "short-video-comment:" + id.uuidString)
                var comment = ShortVideoComment(); comment.commentID = id.uuidString.lowercased(); comment.text = state.text; comment.createdAtMs = state.created
                comment.author = try await MomentsService(im: self.im).profile(row.userID, db: db)
                output.comments.append(comment)
            }
            output.hasMore_p = rows.count > 20
            if output.hasMore_p { output.nextCursor = try self.im.cursor(user: session.userID, resource: "short-video-comments:" + input.videoID, position: rows[19].sequence) }
            return output
        }
    }
    func comment(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ShortVideoCommentRequest.self, from: req)
        let id = try Validation.uuid(input.commentID, field: "comment_id")
        try Validation.text(input.text, field: "text", max: 500)
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "text") }
        var canonical = input; canonical.operationID = ""
        let fingerprint = im.crypto.digest(try canonical.serializedData(), purpose: "short-video-comment")
        return try await write(req, video: input.videoID, operation: input.operationID, bytes: bytes, name: "comment") { user, db in
            let context = "short-video-comment:" + id.uuidString
            if let row = try await ShortVideoCommentRecord.find(id, on: db) {
                let state: ShortVideoCommentState = try self.im.decrypt(row.payload, context: context)
                guard row.userID == user, row.videoID == input.videoID, state.fingerprint == fingerprint else { throw APIError(.conflict, "OPERATION_CONFLICT") }
                return
            }
            // 有界扫描包含删除墓碑，避免互动计数及拉黑过滤退化为无界查询。
            guard try await ShortVideoCommentRecord.query(on: db).filter(\.$videoID == input.videoID).count() < 2000 else {
                throw APIError(.conflict, "SHORT_VIDEO_INTERACTION_LIMIT")
            }
            let row = ShortVideoCommentRecord(); row.id = id; row.userID = user; row.videoID = input.videoID; row.deleted = false
            row.sequence = (try await ShortVideoCommentRecord.query(on: db).sort(\.$sequence, .descending).first()?.sequence ?? 0) + 1
            row.payload = try self.im.encrypt(ShortVideoCommentState(text: input.text, created: self.im.accounts.now, fingerprint: fingerprint), context: context)
            try await row.create(on: db)
        }
    }
    func deleteComment(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(ShortVideoDeleteCommentRequest.self, from: req)
        let id = try Validation.uuid(input.commentID, field: "comment_id")
        return try await write(req, video: input.videoID, operation: input.operationID, bytes: bytes, name: "delete-comment") { user, db in
            guard let row = try await ShortVideoCommentRecord.find(id, on: db), row.videoID == input.videoID else { throw APIError(.notFound, "SHORT_VIDEO_UNAVAILABLE") }
            guard row.userID == user else { throw APIError(.forbidden, "SHORT_VIDEO_OWNER_REQUIRED") }
            let context = "short-video-comment:" + id.uuidString
            var state: ShortVideoCommentState = try self.im.decrypt(row.payload, context: context)
            state.text = ""; row.deleted = true; row.payload = try self.im.encrypt(state, context: context)
            try await row.update(on: db)
        }
    }
    static func eraseAccount(_ user: UUID, db: any Database) async throws {
        try await ShortVideoLikeRecord.query(on: db).filter(\.$userID == user).delete()
        try await ShortVideoCommentRecord.query(on: db).filter(\.$userID == user).delete()
        for row in try await OperationRecord.query(on: db).all() where row.scope.hasPrefix("short-video:") && row.scope.hasSuffix(":" + user.uuidString) {
            try await row.delete(on: db)
        }
    }
}
