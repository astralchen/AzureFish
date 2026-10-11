import Fluent
import Foundation
import SwiftProtobuf
import Vapor

/// 朋友圈所有读取和写入均在共享账号 gate 的事务内重新检查当前好友关系。
final class MomentsService: Sendable {
    let im: IMService
    var accounts: AccountService { im.accounts }
    let media: MediaService?
    init(im: IMService, media: MediaService? = nil) { self.im = im; self.media = media }
    func register(on routes: any RoutesBuilder) {
        let routes = routes.grouped("moments")
        routes.post("list", use: list)
        routes.post("get", use: get)
        routes.on(.POST, "publish", body: .collect(maxSize: "80kb"), use: publish)
        routes.post("result", use: result)
        routes.post("delete", use: delete)
        routes.post("like", use: like)
        routes.on(.POST, "comments", "create", body: .collect(maxSize: "20kb"), use: comment)
        routes.post("comments", "delete", use: deleteComment)
        routes.post("album", use: album)
        routes.post("cover", use: cover)
    }
    /// 检查查看者是否为有效作者本人，或双方保留且均未拉黑的好友。
    func canSee(_ viewer: UUID, _ owner: UUID, db: any Database) async throws -> Bool {
        guard let row = try await UserRecord.find(owner, on: db), try accounts.payload(row).deleted != true else { return false }
        if viewer == owner { return true }
        guard let contact = try await im.contactRecord(viewer, owner, db: db) else { return false }
        let state = try im.contactState(contact)
        guard let a = state.sides?[viewer.uuidString], let b = state.sides?[owner.uuidString] else { return false }
        return a.retained && b.retained && !a.blocked && !b.blocked
    }
    func profile(_ id: UUID, db: any Database) async throws -> IMPublicUser {
        guard let row = try await UserRecord.find(id, on: db) else { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
        let value = try accounts.payload(row)
        var result = IMPublicUser(); result.userID = id.uuidString.lowercased(); result.nickname = value.nickname
        result.avatarID = value.avatarID ?? ""; result.profileVersion = row.version; result.deleted = value.deleted == true
        return result
    }
    func state(_ row: MomentRecord) throws -> MomentState {
        try im.decrypt(row.payload, context: "moment:" + row.requireID().uuidString)
    }
    func save(_ row: MomentRecord, _ value: MomentState, db: any Database) async throws {
        row.payload = try im.encrypt(value, context: "moment:" + row.requireID().uuidString)
        try await row.save(on: db)
    }
    /// 加载当前可见的动态；仅 tombstone 为 true 且查看者为作者时允许返回已删除记录。
    func load(_ id: UUID, viewer: UUID, db: any Database, tombstone: Bool = false) async throws -> MomentRecord {
        guard let row = try await MomentRecord.find(id, on: db), try await canSee(viewer, row.ownerID, db: db) else {
            throw APIError(.notFound, "MOMENT_UNAVAILABLE")
        }
        let post = try MomentPost(serializedBytes: state(row).envelope)
        guard !post.deleted || (tombstone && viewer == row.ownerID) else { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
        return row
    }
    /// 生成查看者可见的互动快照并刷新参与者资料；调用方须先验证动态访问权限。
    func view(_ row: MomentRecord, viewer: UUID, db: any Database) async throws -> MomentPost {
        var post = try MomentPost(serializedBytes: state(row).envelope)
        post.author = try await profile(row.ownerID, db: db)
        var visible: Set<String> = [viewer.uuidString.lowercased()]
        let participants = Set(post.likes.map(\.userID) + post.comments.flatMap { [$0.author.userID, $0.replyTo.userID] })
        for id in participants where !id.isEmpty {
            let user = try Validation.uuid(id, field: "user_id")
            if viewer == row.ownerID { visible.insert(id) }
            else if try await canSee(viewer, user, db: db) { visible.insert(id) }
        }
        post.likes = try await refreshedProfiles(post.likes.filter { visible.contains($0.userID) }, db: db)
        // 回复双方都必须可见，避免通过回复关系暴露非共同好友的身份或正文。
        post.comments = post.comments.filter {
            visible.contains($0.author.userID) && (!$0.hasReplyTo || visible.contains($0.replyTo.userID))
        }
        for index in post.comments.indices {
            post.comments[index].author = try await profile(Validation.uuid(post.comments[index].author.userID, field: "user_id"), db: db)
            if post.comments[index].hasReplyTo {
                post.comments[index].replyTo = try await profile(Validation.uuid(post.comments[index].replyTo.userID, field: "user_id"), db: db)
            }
        }
        return post
    }
    func refreshedProfiles(_ values: [IMPublicUser], db: any Database) async throws -> [IMPublicUser] {
        var result: [IMPublicUser] = []
        for value in values { result.append(try await profile(Validation.uuid(value.userID, field: "user_id"), db: db)) }
        return result
    }
    /// 幂等记录仅保存目标身份；重放仍返回当前权限下的当前版本。
    func write(_ req: Request, operation: String, bytes: Data, name: String,
               body: @escaping @Sendable (SessionRecord, any Database) async throws -> MomentMutationResult) async throws -> Response {
        let id = try Validation.uuid(operation, field: "operation_id")
        return try await im.read(req) { session, db in
            try await self.accounts.limiter.check("moments:" + session.userID.uuidString, limit: 120, now: self.accounts.clock())
            let scope = "moments:" + name + ":" + session.userID.uuidString
            // 操作记录只保存目标身份，不能重放可能已失权或过时的完整响应。
            let identity: MomentMutationResult
            if let record = try await OperationRecord.find(id, on: db) {
                guard record.scope == scope, record.fingerprint == self.accounts.crypto.digest(bytes, purpose: scope) else {
                    throw APIError(.conflict, "OPERATION_CONFLICT")
                }
                identity = try MomentMutationResult(serializedBytes: self.accounts.crypto.open(record.result, context: "operation:" + id.uuidString))
            } else {
                identity = try await body(session, db)
                try await self.accounts.record(id, scope: scope, bytes: bytes, result: identity.serializedData(), session: session, db: db)
            }
            var result = MomentMutationResult()
            if identity.hasPost {
                let row = try await self.load(Validation.uuid(identity.post.postID, field: "post_id"), viewer: session.userID, db: db, tombstone: true)
                result.post = try await self.view(row, viewer: session.userID, db: db)
                guard try result.serializedData().count <= 2 * 1024 * 1024 else { throw APIError(.conflict, "MOMENT_INTERACTION_LIMIT") }
            } else { result.album = try await self.albumValue(session.userID, viewer: session.userID, db: db) }
            return result
        }
    }
    func identity(_ id: UUID) -> MomentMutationResult {
        var result = MomentMutationResult(); result.post.postID = id.uuidString.lowercased(); return result
    }
    /// 校验相册可见性并返回当前封面；无相册记录时返回默认版本和最新所有者资料。
    func albumValue(_ owner: UUID, viewer: UUID, db: any Database) async throws -> MomentAlbum {
        guard try await canSee(viewer, owner, db: db) else { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
        var value = MomentAlbum()
        if let row = try await MomentAlbumRecord.find(owner, on: db) {
            value = try MomentAlbum(serializedBytes: im.crypto.open(row.payload, context: "moment-album:" + owner.uuidString))
        }
        value.owner = try await profile(owner, db: db)
        return value
    }
}
