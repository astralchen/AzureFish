import Fluent
import Foundation
import SwiftProtobuf
import Vapor

extension MomentsService {
    /// 在同一写事务中校验发布身份、绑定媒体并保存动态；重复身份只接受原始内容。
    func publish(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentPublishRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id")
        if !input.text.isEmpty { try Validation.text(input.text, field: "text", max: 2000) }
        guard input.text.utf8.count <= 64 * 1024, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !input.assetIds.isEmpty || !input.videoAssetID.isEmpty,
              input.videoAssetID.isEmpty || input.assetIds.isEmpty,
              input.assetIds.count <= 9, Set(input.assetIds.map { $0.lowercased() }).count == input.assetIds.count else {
            throw APIError(.badRequest, "VALIDATION_FAILED")
        }
        // 内容身份独立于短期操作记录，即使换 operationID，也不能用同一动态 ID 发布不同内容。
        var canonical = input; canonical.operationID = ""; canonical.postID = id.uuidString.lowercased()
        let fingerprint = im.crypto.digest(try canonical.serializedData(), purpose: "moment-publish")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "publish") { session, db in
            if let row = try await MomentRecord.find(id, on: db) {
                guard row.ownerID == session.userID, try self.state(row).fingerprint == fingerprint else { throw APIError(.conflict, "MOMENT_ID_CONFLICT") }
                return self.identity(id)
            }
            var post = MomentPost(); post.postID = id.uuidString.lowercased(); post.author.userID = session.userID.uuidString.lowercased()
            post.text = input.text; post.createdAtMs = self.accounts.now; post.revision = 1
            post.sequence = (try await MomentRecord.query(on: db).sort(\.$sequence, .descending).first()?.sequence ?? 0) + 1
            if !input.assetIds.isEmpty {
                guard let media = self.media else { throw APIError(.serviceUnavailable, "PROCESSOR_UNAVAILABLE") }
                post.images = try await media.attachMoments(input.assetIds, target: id, purpose: "moments_post", user: session.userID, db: db)
            }
            if !input.videoAssetID.isEmpty {
                guard let media = self.media else { throw APIError(.serviceUnavailable, "PROCESSOR_UNAVAILABLE") }
                post.video = try await media.attachMoments([input.videoAssetID], target: id, purpose: "moments_post", kind: "video", user: session.userID, db: db)[0]
            }
            let row = MomentRecord(); row.id = id; row.ownerID = session.userID; row.sequence = post.sequence
            try await self.save(row, MomentState(envelope: post.serializedData(), fingerprint: fingerprint), db: db)
            return self.identity(id)
        }
    }
    /// 仅允许作者删除动态；已删除动态可重复确认而不再次修改版本。
    func delete(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentMutationRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "delete") { session, db in
            let row = try await self.load(id, viewer: session.userID, db: db, tombstone: true)
            guard row.ownerID == session.userID else { throw APIError(.forbidden, "MOMENT_OWNER_REQUIRED") }
            try await self.erase(row, db: db)
            return self.identity(id)
        }
    }
    /// 清空动态内容并保留身份墓碑，随后解除媒体引用；调用方提供所属写事务。
    func erase(_ row: MomentRecord, db: any Database) async throws {
        var state = try state(row); var post = try MomentPost(serializedBytes: state.envelope)
        guard !post.deleted else { return }
        post.deleted = true; post.text = ""; post.images = []; post.clearVideo(); post.likes = []; post.comments = []; post.revision += 1
        state.envelope = try post.serializedData(); state.commentFingerprints = [:]
        try await save(row, state, db: db)
        try await detach(target: row.requireID(), purpose: "moments_post", db: db)
    }
    /// 设置当前用户的点赞目标状态；重复设置相同状态不增加动态版本。
    func like(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentMutationRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "like") { session, db in
            let row = try await self.load(id, viewer: session.userID, db: db)
            var state = try self.state(row); var post = try MomentPost(serializedBytes: state.envelope)
            let user = session.userID.uuidString.lowercased()
            if post.likes.contains(where: { $0.userID == user }) != input.liked {
                post.likes.removeAll { $0.userID == user }
                if input.liked {
                    guard post.likes.count < 500 else { throw APIError(.conflict, "MOMENT_INTERACTION_LIMIT") }
                    var profile = IMPublicUser(); profile.userID = user; post.likes.append(profile)
                }
                post.revision += 1; state.envelope = try post.serializedData(); try await self.save(row, state, db: db)
            }
            return self.identity(id)
        }
    }
    /// 创建带稳定身份的评论；回复目标须为作者或当前查看者可见的评论参与者。
    func comment(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentCommentRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id"), comment = try Validation.uuid(input.commentID, field: "comment_id").uuidString.lowercased()
        try Validation.text(input.text, field: "text", max: 500)
        guard input.text.utf8.count <= 16 * 1024 else { throw APIError(.badRequest, "VALIDATION_FAILED", field: "text") }
        let reply = input.replyToUserID.isEmpty ? nil : try Validation.uuid(input.replyToUserID, field: "reply_to_user_id")
        var canonical = input; canonical.operationID = ""
        let fingerprint = im.crypto.digest(try canonical.serializedData(), purpose: "moment-comment")
        return try await write(req, operation: input.operationID, bytes: bytes, name: "comment") { session, db in
            let row = try await self.load(id, viewer: session.userID, db: db)
            var state = try self.state(row); var post = try MomentPost(serializedBytes: state.envelope)
            let identity = session.userID.uuidString.lowercased() + ":" + comment
            if let prior = state.commentFingerprints[identity] {
                guard prior == fingerprint else { throw APIError(.conflict, "MOMENT_ID_CONFLICT") }
                return self.identity(id)
            }
            guard !post.comments.contains(where: { $0.commentID == comment }) else { throw APIError(.conflict, "MOMENT_ID_CONFLICT") }
            // 上限统计已登记身份而非现存评论，删除评论不会释放可重用的幂等身份配额。
            guard state.commentFingerprints.count < 200 else { throw APIError(.conflict, "MOMENT_INTERACTION_LIMIT") }
            var value = MomentComment(); value.commentID = comment; value.author.userID = session.userID.uuidString.lowercased()
            value.text = input.text; value.createdAtMs = self.accounts.now
            if let reply {
                let visible = try await self.view(row, viewer: session.userID, db: db)
                guard reply == row.ownerID || visible.comments.contains(where: { $0.author.userID == reply.uuidString.lowercased() }) else {
                    throw APIError(.notFound, "MOMENT_UNAVAILABLE")
                }
                value.replyTo.userID = reply.uuidString.lowercased()
            }
            post.comments.append(value); post.revision += 1; state.commentFingerprints[identity] = fingerprint
            state.envelope = try post.serializedData(); try await self.save(row, state, db: db)
            return self.identity(id)
        }
    }
    /// 仅允许评论作者删除自己的评论；保留摘要以阻止旧创建请求恢复已删除内容。
    func deleteComment(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentDeleteCommentRequest.self, from: req)
        let id = try Validation.uuid(input.postID, field: "post_id"), comment = try Validation.uuid(input.commentID, field: "comment_id").uuidString.lowercased()
        return try await write(req, operation: input.operationID, bytes: bytes, name: "delete-comment") { session, db in
            let row = try await self.load(id, viewer: session.userID, db: db)
            var state = try self.state(row); var post = try MomentPost(serializedBytes: state.envelope)
            let user = session.userID.uuidString.lowercased()
            if let target = post.comments.first(where: { $0.commentID == comment }) {
                guard target.author.userID == user else { throw APIError(.forbidden, "MOMENT_OWNER_REQUIRED") }
                post.comments.removeAll { $0.commentID == comment }; post.revision += 1
                state.envelope = try post.serializedData(); try await self.save(row, state, db: db)
            } else if state.commentFingerprints[user + ":" + comment] == nil { throw APIError(.notFound, "MOMENT_UNAVAILABLE") }
            return self.identity(id)
        }
    }
    /// 按预期版本替换或清除当前账号封面；解除旧引用与保存新封面在同一事务完成。
    func cover(_ req: Request) async throws -> Response {
        let (input, bytes) = try requestMessage(MomentCoverRequest.self, from: req)
        return try await write(req, operation: input.operationID, bytes: bytes, name: "cover") { session, db in
            var value = try await self.albumValue(session.userID, viewer: session.userID, db: db)
            guard value.revision == input.expectedRevision else { throw APIError(.conflict, "MOMENT_VERSION_CONFLICT") }
            try await self.detach(target: session.userID, purpose: "moments_cover", db: db)
            value.clearCover()
            if !input.assetID.isEmpty {
                guard let media = self.media else { throw APIError(.serviceUnavailable, "PROCESSOR_UNAVAILABLE") }
                value.cover = try await media.attachMoments([input.assetID], target: session.userID, purpose: "moments_cover", user: session.userID, db: db)[0]
            }
            value.revision += 1
            let row = try await MomentAlbumRecord.find(session.userID, on: db) ?? MomentAlbumRecord(); row.id = session.userID
            row.payload = try self.im.crypto.seal(value.serializedData(), context: "moment-album:" + session.userID.uuidString)
            try await row.save(on: db)
            var result = MomentMutationResult(); result.album.owner.userID = session.userID.uuidString.lowercased(); return result
        }
    }
    /// 解除目标用途的媒体引用；仅当聊天及朋友圈均无引用时恢复资产过期时间。
    func detach(target: UUID, purpose: String, db: any Database) async throws {
        for ref in try await MomentMediaReference.query(on: db).filter(\.$targetID == target).filter(\.$purpose == purpose).all() {
            try await ref.delete(on: db)
            if try await !MediaService.hasReferences(ref.assetID, db: db), let asset = try await MediaAssetRecord.find(ref.assetID, on: db) {
                asset.expiresAt = accounts.now + MediaLimits.lifetime; try await asset.update(on: db)
            }
        }
    }
    /// 在账号删除事务中清除该账号的动态内容、互动和相册引用。
    func eraseAccount(_ user: UUID, db: any Database) async throws {
        for row in try await MomentRecord.query(on: db).filter(\.$ownerID == user).all() { try await erase(row, db: db) }
        // 删除账号也移除其在其他动态中的互动及回复中的个人内容。
        for row in try await MomentRecord.query(on: db).filter(\.$ownerID != user).all() {
            var state = try state(row); var post = try MomentPost(serializedBytes: state.envelope)
            let id = user.uuidString.lowercased(), oldCount = post.likes.count + post.comments.count
            post.likes.removeAll { $0.userID == id }
            post.comments.removeAll { $0.author.userID == id || $0.replyTo.userID == id }
            if oldCount != post.likes.count + post.comments.count {
                post.revision += 1; state.envelope = try post.serializedData(); try await save(row, state, db: db)
            }
        }
        try await detach(target: user, purpose: "moments_cover", db: db)
        try await MomentAlbumRecord.find(user, on: db)?.delete(on: db)
    }
}
