@testable import Server
import Fluent
import Foundation
import SwiftProtobuf
import Testing
import VaporTesting

private func pixabayFixture(id: Int = 125, total: Int = 1, duration: Int = 12, url: String = "https://cdn.pixabay.com/video/test.mp4", bytes: Int = 1024) -> Data {
    Data("""
    {"totalHits":\(total),"hits":[{"id":\(id),"pageURL":"https://pixabay.com/videos/id-\(id)/","tags":"nature","duration":\(duration),"user":"Fixture creator","videos":{"small":{"url":"\(url)","width":720,"height":1280,"size":\(bytes),"thumbnail":"https://cdn.pixabay.com/video/test.jpg"}}}]}
    """.utf8)
}
private actor PixabayCalls {
    var count = 0
    func hit() { count += 1 }
}
private func withShortVideos(provider: PixabayProvider, _ body: (Application) async throws -> Void) async throws {
    let fixture = Fixture(); defer { fixture.clean() }
    let app = try await Application.make(.testing); app.logger.logLevel = .critical
    do {
        try await configure(app, configuration: .init(directory: fixture.directory, key: fixture.key, environmentID: "test", bcryptCost: 4, pixabayProvider: provider))
        try await body(app)
    } catch { try await app.asyncShutdown(); throw error }
    try await app.asyncShutdown()
}
private func videoCall<I: Message, O: Message>(_ app: Application, _ path: String, _ input: I, _ output: O.Type, _ user: AuthResponse) async throws -> O {
    let response = try await send(app, .POST, "/v1/short-videos/" + path, input, token: user.accessToken)
    #expect(response.status == .ok)
    return try decode(output, response)
}
@Suite("短视频内容源与互动", .serialized)
struct ShortVideoTests {
    @Test func detailAndCommentsShareReadLimit() async throws {
        try await withShortVideos(provider: PixabayProvider(key: "fake", fetch: { _ in (pixabayFixture(), 200) })) { app in
            let user = try await auth(app)
            _ = try await videoCall(app, "list", ShortVideoListRequest(), ShortVideoListResponse.self, user)
            let service = try #require(app.storage[ShortVideoServiceKey.self])
            let id = try Validation.uuid(user.userID, field: "user_id")
            for _ in 1..<120 {
                try await service.im.accounts.limiter.check("short-video-read:" + id.uuidString, limit: 120, now: service.im.accounts.clock())
            }
            var video = ShortVideoIdentity(); video.videoID = "pixabay:125"
            var comments = ShortVideoCommentsRequest(); comments.videoID = video.videoID
            #expect(try errorCode(await send(app, .POST, "/v1/short-videos/get", video, token: user.accessToken)) == "RATE_LIMITED")
            #expect(try errorCode(await send(app, .POST, "/v1/short-videos/comments/list", comments, token: user.accessToken)) == "RATE_LIMITED")
        }
    }
    @Test func sourceFilteringAndPagination() throws {
        let now = Date()
        let page = try PixabayProvider.decode(pixabayFixture(total: 40), page: 1, now: now)
        #expect(page.hasMore && page.expires == now.addingTimeInterval(86400))
        #expect(try ShortVideo(serializedBytes: page.videos[0]).videoID == "pixabay:125")
        #expect(try PixabayProvider.decode(pixabayFixture(duration: 61), page: 1, now: now).videos.isEmpty)
        #expect(try PixabayProvider.decode(pixabayFixture(url: "https://attacker.example/a.mp4"), page: 1, now: now).videos.isEmpty)
        #expect(try PixabayProvider.decode(pixabayFixture(bytes: 60 * 1024 * 1024), page: 1, now: now).videos.isEmpty)
        #expect(!PixabayAddress.valid("https://cdn.pixabay.com@evil.example/a", media: true))
        #expect(!PixabayAddress.valid("http://cdn.pixabay.com/a", media: true))
    }
    @Test func cacheCoalescingExpirationAndEncryptedStorage() async throws {
        let calls = PixabayCalls(), clock = TestClock()
        let provider = PixabayProvider(key: "fixture-key", clock: { clock.now() }) { _ in
            await calls.hit(); try await Task.sleep(for: .milliseconds(30)); return (pixabayFixture(), 200)
        }
        try await withShortVideos(provider: provider) { app in
            let service = try #require(app.storage[ShortVideoServiceKey.self])
            async let a = provider.page(1, db: app.db, crypto: service.im.crypto)
            async let b = provider.page(1, db: app.db, crypto: service.im.crypto)
            _ = try await (a, b)
            #expect(await calls.count == 1)
            _ = try await provider.page(1, db: app.db, crypto: service.im.crypto)
            #expect(await calls.count == 1)
            let stored = try #require(try await ShortVideoCacheRecord.find("page:1", on: app.db))
            #expect(!stored.payload.contains("Fixture creator") && !stored.payload.contains("fixture-key"))
            clock.advance(86401)
            _ = try await provider.page(1, db: app.db, crypto: service.im.crypto)
            #expect(await calls.count == 2)
        }
    }
    @Test func missingKeyAndRateLimitAreExplicit() async throws {
        try await withShortVideos(provider: PixabayProvider(key: nil)) { app in
            let user = try await auth(app)
            #expect(try errorCode(await send(app, .POST, "/v1/short-videos/list", ShortVideoListRequest(), token: user.accessToken)) == "SHORT_VIDEO_SOURCE_UNCONFIGURED")
        }
        let calls = PixabayCalls()
        try await withShortVideos(provider: PixabayProvider(key: "fake", fetch: { _ in await calls.hit(); return (Data(), 429) })) { app in
            let user = try await auth(app)
            for _ in 0..<2 {
                #expect(try errorCode(await send(app, .POST, "/v1/short-videos/list", ShortVideoListRequest(), token: user.accessToken)) == "SHORT_VIDEO_SOURCE_LIMITED")
            }
            #expect(await calls.count == 1)
        }
    }
    @Test(arguments: ["http", "json", "transport"])
    func upstreamFailuresDoNotExposeKey(_ failure: String) async throws {
        let key = "fixture-private-key"
        let provider = PixabayProvider(key: key, fetch: { _ in
            if failure == "transport" { throw URLError(.timedOut) }
            return (Data("upstream diagnostic fixture-private-key".utf8), failure == "http" ? 503 : 200)
        })
        try await withShortVideos(provider: provider) { app in
            let user = try await auth(app)
            let response = try await send(app, .POST, "/v1/short-videos/list", ShortVideoListRequest(), token: user.accessToken)
            #expect(try errorCode(response) == "SHORT_VIDEO_SOURCE_FAILED")
            #expect(!String(decoding: response.body.readableBytesView, as: UTF8.self).contains(key))
        }
    }
    @Test func authenticatedPagingLikesCommentsAndDeletion() async throws {
        let provider = PixabayProvider(key: "fake", fetch: { url in
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            return (pixabayFixture(id: page == "2" ? 126 : 125, total: 40), 200)
        })
        try await withShortVideos(provider: provider) { app in
            let a = try await auth(app, name: "video_a"), b = try await auth(app, name: "video_b")
            #expect(try await send(app, .POST, "/v1/short-videos/list", ShortVideoListRequest()).status == .unauthorized)
            let page = try await videoCall(app, "list", ShortVideoListRequest(), ShortVideoListResponse.self, a)
            #expect(page.videos.count == 1 && page.hasMore_p)
            var query = ShortVideoListRequest(); query.cursor = page.nextCursor
            #expect(try await videoCall(app, "list", query, ShortVideoListResponse.self, a).videos.first?.videoID == "pixabay:126")
            #expect(try errorCode(await send(app, .POST, "/v1/short-videos/list", query, token: b.accessToken)) == "INVALID_CURSOR")
            var like = ShortVideoLikeRequest(); like.videoID = "pixabay:125"; like.liked = true; like.operationID = UUID().uuidString
            #expect(try await videoCall(app, "like", like, ShortVideo.self, a).likeCount == 1)
            #expect(try await videoCall(app, "like", like, ShortVideo.self, a).likeCount == 1)
            var comment = ShortVideoCommentRequest(); comment.videoID = like.videoID; comment.commentID = UUID().uuidString; comment.operationID = UUID().uuidString; comment.text = "虚构短视频评论"
            #expect(try await videoCall(app, "comments/create", comment, ShortVideo.self, a).commentCount == 1)
            #expect(try await videoCall(app, "comments/create", comment, ShortVideo.self, a).commentCount == 1)
            var list = ShortVideoCommentsRequest(); list.videoID = like.videoID
            #expect(try await videoCall(app, "comments/list", list, ShortVideoCommentsResponse.self, b).comments.count == 1)
            var deletion = ShortVideoDeleteCommentRequest(); deletion.videoID = like.videoID; deletion.commentID = comment.commentID; deletion.operationID = UUID().uuidString
            #expect(try errorCode(await send(app, .POST, "/v1/short-videos/comments/delete", deletion, token: b.accessToken)) == "SHORT_VIDEO_OWNER_REQUIRED")
            #expect(try await videoCall(app, "comments/delete", deletion, ShortVideo.self, a).commentCount == 0)
            comment.operationID = UUID().uuidString
            #expect(try await videoCall(app, "comments/create", comment, ShortVideo.self, a).commentCount == 0)
            try await ShortVideoService.eraseAccount(Validation.uuid(a.userID, field: "user"), db: app.db)
            #expect(try await ShortVideoLikeRecord.query(on: app.db).count() == 0)
            #expect(try await ShortVideoCommentRecord.query(on: app.db).count() == 0)
            #expect(try await OperationRecord.query(on: app.db).all().filter { $0.scope.hasPrefix("short-video:") }.isEmpty)
        }
    }
    @Test func blockFiltersCommentsAndCounts() async throws {
        try await withShortVideos(provider: PixabayProvider(key: "fake", fetch: { _ in (pixabayFixture(), 200) })) { app in
            let a = try await auth(app, name: "video_block_a"), b = try await auth(app, name: "video_block_b")
            _ = try await videoCall(app, "list", ShortVideoListRequest(), ShortVideoListResponse.self, a)
            var comment = ShortVideoCommentRequest(); comment.videoID = "pixabay:125"; comment.commentID = UUID().uuidString; comment.operationID = UUID().uuidString; comment.text = "可见性测试"
            _ = try await videoCall(app, "comments/create", comment, ShortVideo.self, a)
            try await befriend(app, a, b)
            var get = ContactGetRequest(); get.peerUserID = a.userID
            let relation = try await imCall(app, "contacts/get", get, ContactRelationship.self, b)
            var block = ContactMutationRequest(); block.operationID = UUID().uuidString; block.peerUserID = a.userID; block.action = "block"; block.semanticsVersion = 2; block.expectedRevision = relation.revision
            _ = try await imCall(app, "contacts/mutate", block, ContactRelationship.self, b)
            var identity = ShortVideoIdentity(); identity.videoID = comment.videoID
            #expect(try await videoCall(app, "get", identity, ShortVideo.self, b).commentCount == 0)
            var list = ShortVideoCommentsRequest(); list.videoID = comment.videoID
            #expect(try await videoCall(app, "comments/list", list, ShortVideoCommentsResponse.self, b).comments.isEmpty)
            #expect(try await videoCall(app, "get", identity, ShortVideo.self, a).commentCount == 1)
        }
    }
}
