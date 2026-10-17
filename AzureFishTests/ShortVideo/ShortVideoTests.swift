@testable import AzureFish
import AzureFishAPI
import AzureFishStorage
import CryptoKit
import Foundation
import Testing
import UIKit
import QuickLayoutKit

@Suite("短视频播放与账号生命周期", .serialized)
@MainActor
struct ShortVideoTests {
    @Test func staleReadsCannotRestoreDeletedCommentsOrOverwriteInteraction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-video-race-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID()
        let owner = try await AccountBusinessStorage.acquire(root: root,
            databaseKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            mediaKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "short-video-race", userID: user)
        let moments = MomentsRuntime(preview: [], user: user.uuidString.lowercased())
        try moments.attach(database: owner.resources.database, media: owner.resources.media)
        let service = DelayedShortVideoService(user: user.uuidString.lowercased())
        let runtime = ShortVideoRuntime(); runtime.fixtureMoments = moments; runtime.fixtureAPI = service
        let feed = ShortVideoViewModel(runtime: runtime)
        let comments = ShortVideoCommentsViewModel(runtime: runtime, video: "pixabay:1")
        comments.changed = { feed.update($0) }
        do {
            feed.loadNextPage(); try await settle { !feed.fetching }
            comments.read(reset: true); try await settle { !comments.loading }
            let comment = try #require(comments.comments.first)
            await service.delayDetail()
            feed.refreshCurrent()
            try await waitForHeldRead(service, details: true)
            var committed = try #require(feed.current); committed.commentCount = 2
            feed.update(committed)
            await service.releaseDetail()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(feed.current?.commentCount == 2)

            await service.delayComments()
            comments.read(reset: true)
            try await waitForHeldRead(service, details: false)
            comments.delete(comment)
            try await settle { !comments.busy }
            #expect(!comments.loading)
            await service.releaseComments()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(comments.comments.isEmpty)
            #expect(feed.current?.commentCount == 0)

            await service.restoreComment(comment)
            comments.read(reset: true); try await settle { !comments.loading }
            #expect(comments.comments.count == 1 && feed.current?.commentCount == 1)
            await runtime.stop().value; await moments.stop().value; try await owner.release()
        } catch {
            await service.releaseDetail(); await service.releaseComments()
            await runtime.stop().value; await moments.stop().value; try? await owner.release(); throw error
        }
    }
    private func waitForHeldRead(_ service: DelayedShortVideoService, details: Bool) async throws {
        for _ in 0..<200 {
            if await service.hasHeldRead(details: details) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw APIClientError.invalidResponse
    }
    @Test func rapidPagingRejectsOldCompletionAndHonorsPause() {
        var state = ShortVideoPlaybackState(); state.visible = true
        let old = state.generation
        state.invalidate()
        #expect(!state.accepts(old))
        #expect(state.canPlay)
        state.scrolling = true
        #expect(!state.canPlay)
        #expect(state.accepts(state.generation))
        state.scrolling = false
        state.paused = true
        #expect(!state.canPlay)
        state.obscured = true; state.paused = false
        #expect(!state.canPlay && !state.accepts(state.generation))
        state.obscured = false; state.foreground = false
        #expect(!state.canPlay && !state.accepts(state.generation))
        state.foreground = true; state.visible = false
        #expect(!state.canPlay)
    }
    @Test func encryptedMediaLeaseReleaseAndStopCancelWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-video-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var protectedRoot = root
                var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                try protectedRoot.setResourceValues(flags)
                let user = UUID()
        let owner = try await AccountBusinessStorage.acquire(root: root,
            databaseKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            mediaKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "short-video-test", userID: user)
        let moments = MomentsRuntime(preview: [], user: user.uuidString.lowercased())
        try moments.attach(database: owner.resources.database, media: owner.resources.media)
        let runtime = ShortVideoRuntime(); runtime.fixtureMoments = moments
        let bytes = Data("fictional-video-payload".utf8)
        runtime.fixtureMedia = { _, _ in bytes }
        let item = ShortVideoItem(id: "pixabay:1", author: "Fixture", tags: "", sourceURL: "https://pixabay.com/", videoURL: "", thumbnailURL: "", bytes: Int64(bytes.count), duration: 1, width: 1, height: 1)
        do {
            let (id, url) = try await runtime.work { try await runtime.media(item, thumbnail: false) }
            #expect(try Data(contentsOf: url) == bytes)
            await runtime.release(id)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            runtime.fixtureMedia = { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000); return bytes }
            let task = Task { try await runtime.work { try await runtime.media(item, thumbnail: false) } }
            await Task.yield()
            let old = runtime.epoch
            let stop = runtime.stop()
            #expect(runtime.epoch != old)
            await stop.value
            do { _ = try await task.value; Issue.record("账号停止后旧下载仍成功") } catch is CancellationError {} catch { Issue.record("取消返回意外错误：\(error)") }
            await moments.stop().value; try await owner.release()
        } catch {
            await runtime.stop().value; await moments.stop().value; try? await owner.release(); throw error
        }
    }
    @Test func uncertainCommentRetryKeepsDraftAndIdentityUntilAccountStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-video-model-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID()
        let owner = try await AccountBusinessStorage.acquire(root: root,
            databaseKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
            mediaKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "short-video-model-test", userID: user)
        let moments = MomentsRuntime(preview: [], user: user.uuidString.lowercased())
        try moments.attach(database: owner.resources.database, media: owner.resources.media)
        let service = UncertainShortVideoService(user: user.uuidString.lowercased())
        let runtime = ShortVideoRuntime(); runtime.fixtureMoments = moments; runtime.fixtureAPI = service
        let feed = ShortVideoViewModel(runtime: runtime)
        let comments = ShortVideoCommentsViewModel(runtime: runtime, video: "pixabay:1")
        do {
            feed.loadNextPage(); feed.loadNextPage()
            try await settle { !feed.fetching }
            #expect(feed.items.count == 1)
            #expect(await service.listCalls == 1)
            comments.draft = "fictional comment"
            comments.submit(); comments.submit()
            try await settle { !comments.busy }
            #expect(comments.draft == "fictional comment")
            #expect(comments.errorKey != nil)
            let pending = try #require(comments.pending)
            comments.submit()
            try await settle { !comments.busy && !comments.loading }
            #expect(comments.draft.isEmpty)
            #expect(comments.comments.count == 1)
            let calls = await service.commentCalls
            #expect(calls.count == 2)
            #expect(calls.allSatisfy { $0.0 == pending.id && $0.1 == pending.operation })
            comments.draft = "cleared on logout"
            await runtime.stop().value
            #expect(feed.items.isEmpty && comments.draft.isEmpty && comments.comments.isEmpty)
            #expect(runtime.api == nil)
            await moments.stop().value; try await owner.release()
        } catch {
            await runtime.stop().value; await moments.stop().value; try? await owner.release(); throw error
        }
    }
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("短视频状态未在测试期限内完成")
    }
    @Test func centerTouchesReachVideoListWhileActionsRemainInteractive() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let feed = ShortVideoFeedView(), controls = ShortVideoControlsView()
        root.view.addSubview(feed); root.view.addSubview(controls)
        feed.frame = root.view.bounds; controls.frame = root.view.bounds
        feed.renderStatus(errorKey: nil, empty: false, hasMore: false)
        controls.render(item: .init(id: "pixabay:1", author: "Fixture", tags: "", sourceURL: "", videoURL: "", thumbnailURL: "", bytes: 1, duration: 1, width: 1, height: 1), paused: false, muted: true, mutating: false, ready: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        feed.quickLayoutIfNeeded(); controls.quickLayoutIfNeeded(); root.view.layoutIfNeeded()
        let center = controls.play.convert(CGPoint(x: controls.play.bounds.midX, y: controls.play.bounds.midY), to: root.view)
        let hit = try #require(root.view.hitTest(center, with: nil))
        #expect(hit === feed.list || hit.isDescendant(of: feed.list))
        let action = controls.like.convert(CGPoint(x: controls.like.bounds.midX, y: controls.like.bounds.midY), to: root.view)
        let button = try #require(root.view.hitTest(action, with: nil))
        #expect(button === controls.like || button.isDescendant(of: controls.like))
    }
    @Test func sourceErrorLocalizationIsDistinct() {
        #expect(APIErrorCode(rawValue: "SHORT_VIDEO_SOURCE_UNCONFIGURED") == .shortVideoSourceUnconfigured)
        #expect(APIErrorCode(rawValue: "SHORT_VIDEO_SOURCE_LIMITED") == .shortVideoSourceLimited)
    }
}

/// 返回写入前快照的受控读取，模拟已抵达服务端且取消无法撤回的请求。
private actor DelayedShortVideoService: ShortVideoServing {
    var item = ShortVideoItem(id: "pixabay:1", author: "Fixture", tags: "", sourceURL: "https://pixabay.com/", videoURL: "", thumbnailURL: "", bytes: 1, duration: 1, width: 1, height: 1, commentCount: 1)
    var messages: [VideoComment]
    private var delayNextDetail = false, delayNextComments = false
    private var detailWait: CheckedContinuation<Void, Never>?, commentsWait: CheckedContinuation<Void, Never>?
    init(user: String) {
        messages = [.init(id: UUID().uuidString, author: .init(id: user, nickname: "Fixture", version: 1, avatarID: nil, deleted: false), text: "old comment", createdAt: 1)]
    }
    func delayDetail() { delayNextDetail = true }
    func delayComments() { delayNextComments = true }
    func hasHeldRead(details: Bool) -> Bool { details ? detailWait != nil : commentsWait != nil }
    func releaseDetail() { detailWait?.resume(); detailWait = nil }
    func releaseComments() { commentsWait?.resume(); commentsWait = nil }
    func restoreComment(_ comment: VideoComment) { messages = [comment]; item.commentCount = 1 }
    func list(cursor: String) async throws -> ShortVideoPage { .init(videos: [item], cursor: "", hasMore: false) }
    func get(_ id: String) async throws -> ShortVideoItem {
        let snapshot = item
        if delayNextDetail { delayNextDetail = false; await withCheckedContinuation { detailWait = $0 } }
        return snapshot
    }
    func comments(_ id: String, cursor: String) async throws -> VideoCommentsPage {
        let snapshot = messages
        if delayNextComments { delayNextComments = false; await withCheckedContinuation { commentsWait = $0 } }
        return .init(comments: snapshot, cursor: "", hasMore: false)
    }
    func like(_ id: String, liked: Bool, operation: UUID) async throws -> ShortVideoItem { item }
    func comment(_ video: String, id: UUID, text: String, operation: UUID) async throws -> ShortVideoItem { item }
    func deleteComment(_ video: String, id: String, operation: UUID) async throws -> ShortVideoItem {
        messages.removeAll { $0.id == id }; item.commentCount = Int64(messages.count); return item
    }
}

/// 首次创建已在替身服务接受，但响应丢失，重试必须使用相同身份。
private actor UncertainShortVideoService: ShortVideoServing {
    let user: String
    var listCalls = 0
    var commentCalls: [(UUID, UUID)] = []
    var messages: [VideoComment] = []
    var item = ShortVideoItem(id: "pixabay:1", author: "Fixture", tags: "", sourceURL: "https://pixabay.com/", videoURL: "", thumbnailURL: "", bytes: 1, duration: 1, width: 1, height: 1)
    init(user: String) { self.user = user }
    func list(cursor: String) async throws -> ShortVideoPage {
        listCalls += 1
        return .init(videos: [item], cursor: "", hasMore: false)
    }
    func get(_ id: String) async throws -> ShortVideoItem { item }
    func like(_ id: String, liked: Bool, operation: UUID) async throws -> ShortVideoItem { item }
    func comments(_ id: String, cursor: String) async throws -> VideoCommentsPage { .init(comments: messages, cursor: "", hasMore: false) }
    func comment(_ video: String, id: UUID, text: String, operation: UUID) async throws -> ShortVideoItem {
        commentCalls.append((id, operation))
        if messages.isEmpty {
            messages = [.init(id: id.uuidString, author: .init(id: user, nickname: "Fixture", version: 1, avatarID: nil, deleted: false), text: text, createdAt: 1)]
            item.commentCount = 1
            throw APIClientError.invalidResponse
        }
        return item
    }
    func deleteComment(_ video: String, id: String, operation: UUID) async throws -> ShortVideoItem { item }
}
