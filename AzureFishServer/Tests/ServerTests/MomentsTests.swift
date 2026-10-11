@testable import Server
@preconcurrency import AVFoundation
import Fluent
import FluentSQLiteDriver
import SQLKit
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

func momentsCall<I: Message, O: Message>(_ app: Application, _ path: String, _ input: I, _ output: O.Type, _ user: AuthResponse) async throws -> O {
    let response = try await send(app, .POST, "/v1/moments/" + path, input, token: user.accessToken)
    guard response.status == .ok else { throw APIError(response.status, try errorCode(response)) }
    return try decode(output, response)
}
func momentInput(_ text: String = "虚构朋友圈") -> MomentPublishRequest {
    var value = MomentPublishRequest(); value.operationID = UUID().uuidString; value.postID = UUID().uuidString; value.text = text; return value
}
@Suite("朋友圈权限与事务", .serialized)
/// 覆盖好友可见性、发布及互动身份、分页权限和媒体绑定失败的事务边界。
struct MomentsTests {
    @Test func friendsProjectionRepliesAndDeletion() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "moment_a"), b = try await auth(app, name: "moment_b"), c = try await auth(app, name: "moment_c")
            try await befriend(app, a, b); try await befriend(app, a, c)
            let input = momentInput()
            let post = try await momentsCall(app, "publish", input, MomentMutationResult.self, a).post
            var comment = MomentCommentRequest(); comment.operationID = UUID().uuidString; comment.postID = post.postID
            comment.commentID = UUID().uuidString; comment.text = "C 的评论"
            _ = try await momentsCall(app, "comments/create", comment, MomentMutationResult.self, c)
            var get = MomentsGetRequest(); get.postIds = [post.postID]
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, b).posts[0].comments.isEmpty)
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, a).posts[0].comments.count == 1)
            var reply = comment; reply.operationID = UUID().uuidString; reply.commentID = UUID().uuidString
            reply.replyToUserID = c.userID; reply.text = "回复 C"
            #expect(try errorCode(await send(app, .POST, "/v1/moments/comments/create", reply, token: b.accessToken)) == "MOMENT_UNAVAILABLE")
            _ = try await momentsCall(app, "comments/create", reply, MomentMutationResult.self, a)
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, b).posts[0].comments.isEmpty)
            try await befriend(app, b, c)
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, b).posts[0].comments.count == 2)
            var remove = MomentMutationRequest(); remove.operationID = UUID().uuidString; remove.postID = post.postID
            #expect(try errorCode(await send(app, .POST, "/v1/moments/delete", remove, token: b.accessToken)) == "MOMENT_OWNER_REQUIRED")
            #expect(try await momentsCall(app, "delete", remove, MomentMutationResult.self, a).post.deleted)
            let replay = try await momentsCall(app, "publish", input, MomentMutationResult.self, a).post
            #expect(replay.deleted && replay.text.isEmpty && replay.comments.isEmpty)
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, b).unavailableIds == [post.postID])
        }
    }
    @Test func stablePublishLikeAndCommentIdentities() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "moment_a")
            let input = momentInput()
            let post = try await momentsCall(app, "publish", input, MomentMutationResult.self, a).post
            var again = input; again.operationID = UUID().uuidString
            #expect(try await momentsCall(app, "publish", again, MomentMutationResult.self, a).post.postID == post.postID)
            again.text = "different"; again.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .POST, "/v1/moments/publish", again, token: a.accessToken)) == "MOMENT_ID_CONFLICT")
            var like = MomentMutationRequest(); like.operationID = UUID().uuidString; like.postID = post.postID; like.liked = true
            let first = try await momentsCall(app, "like", like, MomentMutationResult.self, a).post
            #expect(try await momentsCall(app, "like", like, MomentMutationResult.self, a).post.revision == first.revision)
            var unlike = like; unlike.operationID = UUID().uuidString; unlike.liked = false
            _ = try await momentsCall(app, "like", unlike, MomentMutationResult.self, a)
            #expect(try await momentsCall(app, "like", like, MomentMutationResult.self, a).post.likes.isEmpty)
            var comment = MomentCommentRequest(); comment.operationID = UUID().uuidString; comment.commentID = UUID().uuidString
            comment.postID = post.postID; comment.text = "delete me"
            _ = try await momentsCall(app, "comments/create", comment, MomentMutationResult.self, a)
            var remove = MomentDeleteCommentRequest(); remove.operationID = UUID().uuidString; remove.postID = post.postID; remove.commentID = comment.commentID
            _ = try await momentsCall(app, "comments/delete", remove, MomentMutationResult.self, a)
            comment.operationID = UUID().uuidString
            #expect(try await momentsCall(app, "comments/create", comment, MomentMutationResult.self, a).post.comments.isEmpty)
        }
    }
    @Test func paginationAuthorizationAndAtomicMediaFailure() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "moment_a"), b = try await auth(app, name: "moment_b")
            for _ in 0..<3 { _ = try await momentsCall(app, "publish", momentInput(), MomentMutationResult.self, a) }
            #expect(try await momentsCall(app, "list", MomentsListRequest(), MomentsListResponse.self, b).posts.isEmpty)
            try await befriend(app, a, b)
            var query = MomentsListRequest(); query.limit = 1
            let page = try await momentsCall(app, "list", query, MomentsListResponse.self, b)
            #expect(page.posts.count == 1 && page.hasMore_p)
            _ = try await momentsCall(app, "publish", momentInput(), MomentMutationResult.self, a)
            query.cursor = page.nextCursor
            let next = try await momentsCall(app, "list", query, MomentsListResponse.self, b)
            #expect(next.posts[0].sequence < page.posts[0].sequence)
            #expect(try errorCode(await send(app, .POST, "/v1/moments/list", query, token: a.accessToken)) == "INVALID_CURSOR")
            var broken = momentInput(); broken.assetIds = [UUID().uuidString]
            let count = try await MomentRecord.query(on: app.db).count()
            #expect(try await send(app, .POST, "/v1/moments/publish", broken, token: a.accessToken).status == .notFound)
            #expect(try await MomentRecord.query(on: app.db).count() == count)
            var contactQuery = ContactGetRequest(); contactQuery.peerUserID = a.userID
            let contact = try await imCall(app, "contacts/get", contactQuery, ContactRelationship.self, b)
            var block = ContactMutationRequest(); block.operationID = UUID().uuidString; block.peerUserID = a.userID
            block.expectedRevision = contact.revision; block.semanticsVersion = 2; block.action = "block"
            _ = try await imCall(app, "contacts/mutate", block, ContactRelationship.self, b)
            #expect(try await momentsCall(app, "list", MomentsListRequest(), MomentsListResponse.self, b).posts.isEmpty)
            var get = MomentsGetRequest(); get.postIds = page.posts.map(\.postID)
            #expect(try await momentsCall(app, "get", get, MomentsGetResponse.self, b).posts.isEmpty)
        }
    }
}

@Suite("朋友圈图片闭环", .serialized)
/// 覆盖无聊天会话的媒体上传、失权后的授权撤销及封面替换。
struct MomentsMediaTests {
    @Test func uploadWithoutConversationGrantRevocationAndCoverReplacement() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "moment_media_a"), b = try await auth(app, name: "moment_media_b"), c = try await auth(app, name: "moment_media_c")
            try await befriend(app, a, b)
            let bytes = try mediaFixture("preview-image-08.png")
            func upload(_ purpose: String) async throws -> MediaAsset {
                var input = MediaCreateRequest(); input.operationID = UUID().uuidString; input.kind = "image"; input.purpose = purpose
                var file = MediaResourceInput(); file.role = "original"; file.filename = "sample.png"; file.mimeType = "image/png"
                file.byteCount = Int64(bytes.count); file.sha256 = LocalMediaBlobStore.hash(bytes); input.resources = [file]
                let created = try await http.call("v1/media/assets/create", input, MediaAssetStatus.self, user: a)
                for index in 0..<Int(created.uploads[0].partCount) {
                    let start = index * MediaLimits.chunk
                    try await http.upload(created.uploads[0], bytes: Data(bytes[start..<min(bytes.count, start + MediaLimits.chunk)]), index: index, user: a)
                }
                let ready = try await http.finish(created.assetID, user: a)
                #expect(ready.state == "ready")
                return ready.asset
            }
            let image = try await upload("moments_post")
            var broken = momentInput(); broken.assetIds = [image.assetID, UUID().uuidString]
            #expect(try await send(app, .POST, "/v1/moments/publish", broken, token: a.accessToken).status == .notFound)
            #expect(try await MomentMediaReference.query(on: app.db).count() == 0)
            #expect(try await MomentRecord.query(on: app.db).count() == 0)
            #expect(try await OperationRecord.find(Validation.uuid(broken.operationID, field: "operation_id"), on: app.db) == nil)
            var input = momentInput(); input.assetIds = [image.assetID]
            let post = try await momentsCall(app, "publish", input, MomentMutationResult.self, a).post
            #expect(post.images.count == 1)
            let resource = try #require(image.resources.first { $0.role == "original" })
            var grantInput = MediaAuthorizeRequest(); grantInput.resourceID = resource.resourceID
            grantInput.purpose = "moments_post"; grantInput.momentsTargetID = post.postID
            let grant = try await http.call("v1/media/resources/authorize", grantInput, MediaDownloadGrant.self, user: b)
            #expect(try await http.raw("GET", "v1/media/resources/\(resource.resourceID)/content", token: b.accessToken, headers: ["X-Media-Grant": grant.token]).1.statusCode == 200)
            #expect(try await send(app, .POST, "/v1/media/resources/authorize", grantInput, token: c.accessToken).status == .notFound)
            var contactQuery = ContactGetRequest(); contactQuery.peerUserID = a.userID
            var relation = try await imCall(app, "contacts/get", contactQuery, ContactRelationship.self, b)
            var change = ContactMutationRequest(); change.operationID = UUID().uuidString; change.peerUserID = a.userID
            change.semanticsVersion = 2; change.expectedRevision = relation.revision; change.action = "block"
            relation = try await imCall(app, "contacts/mutate", change, ContactRelationship.self, b)
            #expect(try await http.raw("GET", "v1/media/resources/\(resource.resourceID)/content", token: b.accessToken, headers: ["X-Media-Grant": grant.token]).1.statusCode == 404)
            change.operationID = UUID().uuidString; change.expectedRevision = relation.revision; change.action = "unblock"
            _ = try await imCall(app, "contacts/mutate", change, ContactRelationship.self, b)
            var cancel = MediaAssetMutation(); cancel.operationID = UUID().uuidString; cancel.assetID = image.assetID
            #expect(try errorCode(await send(app, .POST, "/v1/media/assets/cancel", cancel, token: a.accessToken)) == "MEDIA_IN_USE")
            var remove = MomentMutationRequest(); remove.operationID = UUID().uuidString; remove.postID = post.postID
            _ = try await momentsCall(app, "delete", remove, MomentMutationResult.self, a)
            #expect(try await http.raw("GET", "v1/media/resources/\(resource.resourceID)/content", token: b.accessToken, headers: ["X-Media-Grant": grant.token]).1.statusCode == 404)
            #expect(try await MomentMediaReference.query(on: app.db).count() == 0)
            let coverImage = try await upload("moments_cover")
            var cover = MomentCoverRequest(); cover.operationID = UUID().uuidString; cover.assetID = coverImage.assetID
            let album = try await momentsCall(app, "cover", cover, MomentMutationResult.self, a).album
            #expect(album.hasCover && album.revision == 1)
            var wrong = momentInput(); wrong.assetIds = [coverImage.assetID]
            #expect(try errorCode(await send(app, .POST, "/v1/moments/publish", wrong, token: a.accessToken)) == "MEDIA_NOT_READY")
            var reset = MomentCoverRequest(); reset.operationID = UUID().uuidString; reset.expectedRevision = album.revision
            #expect(try await !momentsCall(app, "cover", reset, MomentMutationResult.self, a).album.hasCover)
            #expect(try await !momentsCall(app, "cover", cover, MomentMutationResult.self, a).album.hasCover)
        }
    }
}

@Suite("朋友圈迁移", .serialized)
/// 检查含既有聊天媒体数据时，朋友圈迁移仍保留原记录和外键关系。
struct MomentsMigrationTests {
    @Test func populatedChatMediaSurvivesMigration() async throws {
        let fixture = Fixture(); defer { fixture.clean() }
        let app = try await Application.make(.testing); app.logger.logLevel = .critical
        do {
            app.databases.use(.sqlite(.memory), as: .sqlite)
            app.migrations.add(CreateSchema()); app.migrations.add(CreateIMSchema()); app.migrations.add(CreateMediaSchema())
            try await app.autoMigrate()
            let sql = try #require(app.db as? any SQLDatabase)
            // 使用最小合法外键图验证表重建保留全部身份，不依赖新模型写入旧字段。
            let user = UUID().uuidString, conversation = UUID().uuidString, message = UUID().uuidString, asset = UUID().uuidString
            try await sql.raw("INSERT INTO users (id, account_digest, version, payload) VALUES (\(bind: user), 'fixture', 1, 'opaque')").run()
            try await sql.raw("INSERT INTO im_conversations (id, pair_key, payload) VALUES (\(bind: conversation), 'fixture', 'opaque')").run()
            try await sql.raw("INSERT INTO im_messages (id, conversation_id, sequence, client_key, payload) VALUES (\(bind: message), \(bind: conversation), 1, 'fixture', 'opaque')").run()
            try await sql.raw("INSERT INTO media_assets (id, owner_id, conversation_id, state, expires_at, reserved_bytes, generation, payload) VALUES (\(bind: asset), \(bind: user), \(bind: conversation), 'ready', 0, 100, 1, 'opaque')").run()
            try await sql.raw("INSERT INTO media_message_references (id, asset_id, message_id) VALUES (\(bind: UUID().uuidString), \(bind: asset), \(bind: message))").run()
            app.migrations.add(CreateMomentsSchema()); try await app.autoMigrate()
            #expect(try await MediaAssetRecord.query(on: app.db).first()?.purpose == "chat")
            #expect(try await MediaReferenceRecord.query(on: app.db).count() == 1)
            #expect(try await sql.raw("PRAGMA foreign_key_check").all().isEmpty)
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}

@Suite("朋友圈账号删除", .serialized)
/// 检查账号删除后自身动态和其他动态中的个人互动均被清理。
struct MomentsDeletionTests {
    @Test func deletionClearsPostsAndPeerInteractions() async throws {
        try await withServer { app, _ in
            let a = try await auth(app, name: "moment_delete_a"), b = try await auth(app, name: "moment_delete_b")
            try await befriend(app, a, b)
            let own = try await momentsCall(app, "publish", momentInput(), MomentMutationResult.self, a).post
            let peer = try await momentsCall(app, "publish", momentInput(), MomentMutationResult.self, b).post
            var comment = MomentCommentRequest(); comment.operationID = UUID().uuidString; comment.commentID = UUID().uuidString
            comment.postID = peer.postID; comment.text = "private comment"
            _ = try await momentsCall(app, "comments/create", comment, MomentMutationResult.self, a)
            var proof = ReauthenticateRequest(); proof.operationID = UUID().uuidString; proof.password = registration().password; proof.action = "delete_account"
            let token = try decode(ReauthenticateResponse.self, await send(app, .POST, "/v1/auth/reauthenticate", proof, token: a.accessToken)).token
            var request = AccountSecurityRequest(); request.operationID = UUID().uuidString; request.reauthToken = token
            #expect(try await send(app, .POST, "/v1/me/security/delete_account", request, token: a.accessToken).status == .accepted)
            var get = MomentsGetRequest(); get.postIds = [own.postID, peer.postID]
            let result = try await momentsCall(app, "get", get, MomentsGetResponse.self, b)
            #expect(result.posts.count == 1 && result.posts[0].comments.isEmpty && result.unavailableIds == [own.postID])
        }
    }
}

@Suite("朋友圈视频", .serialized)
/// 覆盖视频发布、权限、幂等重放及发布端对权威时长的复核。
struct MomentsVideoTests {
    @Test func videoPublishPermissionsReplayAndDuration() async throws {
        try await withMediaHTTP { app, _, http in
            let a = try await auth(app, name: "moment_video_a"), b = try await auth(app, name: "moment_video_b"), c = try await auth(app, name: "moment_video_c")
            try await befriend(app, a, b)
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let source = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/live-photo.mov")
            let exporter = try #require(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetMediumQuality))
            exporter.outputURL = fileURL; exporter.outputFileType = .mp4
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { continuation.resume() } }
            #expect(exporter.status == .completed)
            let bytes = try Data(contentsOf: fileURL)
            var input = MediaCreateRequest(); input.operationID = UUID().uuidString; input.kind = "video"; input.purpose = "moments_post"
            var resource = MediaResourceInput(); resource.role = "original"; resource.filename = "video.mp4"; resource.mimeType = "video/mp4"
            resource.byteCount = Int64(bytes.count); resource.sha256 = LocalMediaBlobStore.hash(bytes); input.resources = [resource]
            var invalid = input; invalid.purpose = "moments_cover"
            #expect(try errorCode(await send(app, .POST, "/v1/media/assets/create", invalid, token: a.accessToken)) == "VALIDATION_FAILED")
            let created = try await http.call("v1/media/assets/create", input, MediaAssetStatus.self, user: a)
            for index in 0..<Int(created.uploads[0].partCount) {
                let start = index * MediaLimits.chunk
                try await http.upload(created.uploads[0], bytes: Data(bytes[start..<min(bytes.count, start + MediaLimits.chunk)]), index: index, user: a)
            }
            let ready = try await http.finish(created.assetID, user: a)
            #expect(ready.state == "ready")
            #expect(ready.asset.durationMs > 0 && ready.asset.durationMs <= 60_000)
            #expect(Set(ready.asset.resources.map(\.role)) == ["original", "cover"])
            var publish = momentInput(""); publish.videoAssetID = ready.assetID
            var mixed = publish; mixed.assetIds = [ready.assetID]
            #expect(try errorCode(await send(app, .POST, "/v1/moments/publish", mixed, token: a.accessToken)) == "VALIDATION_FAILED")
            #expect(try await MomentRecord.query(on: app.db).count() == 0)
            var wrongKind = momentInput(); wrongKind.assetIds = [ready.assetID]
            #expect(try errorCode(await send(app, .POST, "/v1/moments/publish", wrongKind, token: a.accessToken)) == "MEDIA_NOT_READY")
            #expect(try await MomentMediaReference.query(on: app.db).count() == 0)
            // 在发布端独立复核处理器的权威元数据，不接受超长记录。
            let row = try #require(try await MediaAssetRecord.find(UUID(uuidString: ready.assetID), on: app.db))
            let service = try #require(app.storage[MediaServiceKey.self])
            var state = try service.assetState(row), metadata = ready.asset
            for duration in [Int64(0), 60_001] {
                metadata.durationMs = duration; state.metadata = try metadata.serializedData(); try await service.save(row, state, db: app.db)
                #expect(try errorCode(await send(app, .POST, "/v1/moments/publish", publish, token: a.accessToken)) == "VALIDATION_FAILED")
                #expect(try await MomentMediaReference.query(on: app.db).count() == 0)
            }
            metadata.durationMs = 60_000; state.metadata = try metadata.serializedData(); try await service.save(row, state, db: app.db)
            let post = try await momentsCall(app, "publish", publish, MomentMutationResult.self, a).post
            #expect(post.hasVideo && post.images.isEmpty && post.video.durationMs == 60_000)
            #expect(try await momentsCall(app, "publish", publish, MomentMutationResult.self, a).post == post)
            var identity = MomentIdentityRequest(); identity.postID = post.postID
            #expect(try await momentsCall(app, "result", identity, MomentPost.self, a).postID == post.postID)
            var grants: [(MediaResource, MediaDownloadGrant)] = []
            for resource in ready.asset.resources {
                var request = MediaAuthorizeRequest(); request.resourceID = resource.resourceID; request.purpose = "moments_post"; request.momentsTargetID = post.postID
                let grant = try await http.call("v1/media/resources/authorize", request, MediaDownloadGrant.self, user: b)
                grants.append((resource, grant))
                #expect(try await send(app, .POST, "/v1/media/resources/authorize", request, token: c.accessToken).status == .notFound)
            }
            var contactQuery = ContactGetRequest(); contactQuery.peerUserID = a.userID
            let contact = try await imCall(app, "contacts/get", contactQuery, ContactRelationship.self, b)
            var block = ContactMutationRequest(); block.operationID = UUID().uuidString; block.peerUserID = a.userID
            block.expectedRevision = contact.revision; block.semanticsVersion = 2; block.action = "block"
            _ = try await imCall(app, "contacts/mutate", block, ContactRelationship.self, b)
            for (resource, grant) in grants {
                #expect(try await http.raw("GET", "v1/media/resources/\(resource.resourceID)/content", token: b.accessToken, headers: ["X-Media-Grant": grant.token]).1.statusCode == 404)
            }
            var remove = MomentMutationRequest(); remove.operationID = UUID().uuidString; remove.postID = post.postID
            #expect(try await !momentsCall(app, "delete", remove, MomentMutationResult.self, a).post.hasVideo)
            let replay = try await momentsCall(app, "publish", publish, MomentMutationResult.self, a).post
            #expect(replay.deleted && !replay.hasVideo)
            #expect(try await MomentMediaReference.query(on: app.db).count() == 0)
        }
    }
}
