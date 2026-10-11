import AzureFishAPI
import AzureFishChat
import AzureFishMoments
import AzureFishNetwork
import AzureFishProtocol
import AzureFishStorage
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

private actor MomentsTestTransport: HTTPTransport {
    let account = AccountTestTransport()
    var publications: [Data] = []
    var stored: MomentPost?
    var drop = true
    var delay = false
    var paginating = false
    var failNextPage = true
    var pageCursors: [String] = []
    var albumRequests = 0
    var likeRequests = 0
    func enablePagination() { paginating = true }
    func allowNextPage() { failNextPage = false }
    func delayResponses() { delay = true }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        func response<M: SwiftProtobuf.Message>(_ value: M) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try value.serializedData())
        }
        if request.url.path == "/v1/moments/publish" {
            let bytes = try #require(request.body); publications.append(bytes)
            let input = try MomentPublishRequest(serializedBytes: bytes)
            var post = MomentPost(); post.postID = input.postID; post.text = input.text; post.revision = 1; post.sequence = 1
            post.author.userID = try sampleCredentials().userID.uuidString.lowercased(); post.author.nickname = "Fixture"; stored = post
            if delay { try? await Task.sleep(nanoseconds: 300_000_000) }
            if drop { throw URLError(.networkConnectionLost) }
            var value = MomentMutationResult(); value.post = post; return try response(value)
        }
        if request.url.path == "/v1/moments/result", let stored { return try response(stored) }
        if request.url.path == "/v1/moments/like" {
            likeRequests += 1
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        if request.url.path == "/v1/moments/list" {
            guard paginating else { return try response(MomentsListResponse()) }
            let bytes = try #require(request.body)
            let input = try MomentsListRequest(serializedBytes: bytes)
            pageCursors.append(input.cursor)
            if !input.cursor.isEmpty {
                try await Task.sleep(nanoseconds: 100_000_000)
                if failNextPage { return HTTPResponse(statusCode: 400, headers: [:], body: Data()) }
            }
            var post = MomentPost()
            post.postID = input.cursor.isEmpty ? "first" : "second"
            post.author.userID = try sampleCredentials().userID.uuidString.lowercased()
            post.author.nickname = "Fixture"; post.text = post.postID; post.revision = 1
            post.sequence = input.cursor.isEmpty ? 2 : 1
            var value = MomentsListResponse(); value.posts = [post]
            value.hasMore_p = input.cursor.isEmpty; value.nextCursor = input.cursor.isEmpty ? "cursor-1" : ""
            return try response(value)
        }
        if request.url.path == "/v1/moments/get" { return try response(MomentsGetResponse()) }
        if request.url.path == "/v1/moments/album" {
            albumRequests += 1
            var album = MomentAlbum(); album.owner.userID = try sampleCredentials().userID.uuidString.lowercased()
            return try response(album)
        }
        return try await account.send(request)
    }
}

@MainActor
@Suite("朋友圈发布恢复", .serialized)
/// 使用可控网络响应验证续页恢复和发布响应丢失后的对账。
struct MomentsRuntimeTests {
    @Test func nextPageFailureKeepsCursorAndRetryDoesNotReloadAlbum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MomentsTestTransport(), keys = MemorySecureValues(), credentials = try sampleCredentials()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let repository = UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID)
        try repository.save(AccountProfile(userID: credentials.userID, accountName: "fictional_user", nickname: "Fixture", bio: "", version: 1))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)), store: credentialStore, repository: repository)
        await session.restore(); try #require(!session.readOnly)
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("main.sqlite"), key: Data(repeating: 41, count: 32), environment: credentials.environmentID, userID: credentials.userID, migrations: [MomentsStore.migration])
        let media = try EncryptedMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 42, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let chat = ChatRuntime(session: session), runtime = chat.moments
        await transport.enablePagination()
        try runtime.attach(database: database, media: media)
        defer { try? database.close() }
        for _ in 0..<200 {
            if runtime.canLoadNextPage(author: "") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(runtime.canLoadNextPage(author: ""))
        #expect(!runtime.canLoadNextPage(author: "another-author"))
        let controller = MomentsViewController(runtime: runtime)
        let window = try makeVisibleTestWindow(rootViewController: controller, size: CGSize(width: 390, height: 1600))
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        func collection(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        let list = try #require(collection(in: controller.view))
        for _ in 0..<200 {
            if runtime.loadingPageAuthor != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let albums = await transport.albumRequests
        #expect(runtime.loadingPageAuthor == "")
        #expect(!runtime.canLoadNextPage(author: ""))
        try await runtime.refresh(next: true)
        for _ in 0..<200 {
            if runtime.pageFailure(author: "") != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<5 { controller.feedView.scrollViewDidScroll(list) }
        for _ in 0..<100 {
            controller.view.layoutIfNeeded(); list.layoutIfNeeded()
            if list.visibleCells.contains(where: { $0.accessibilityIdentifier == "moments.pagination.failed" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(list.visibleCells.map(\.accessibilityIdentifier).contains("moments.pagination.failed"))
        #expect(runtime.pageFailure(author: "") != nil)
        #expect(controller.viewModel.state.footer == .failed)
        #expect(!controller.viewModel.requestingPage)
        #expect(runtime.failure == nil)
        #expect(!runtime.canLoadNextPage(author: ""))
        #expect(runtime.canLoadNextPage(author: "", retry: true))
        #expect(runtime.posts.map(\.id) == ["first"])
        #expect(await transport.pageCursors.filter { !$0.isEmpty } == ["cursor-1"])
        await transport.allowNextPage()
        list.delegate?.collectionView?(list, didSelectItemAt: IndexPath(item: 0, section: 1))
        for _ in 0..<200 {
            if !runtime.hasMore(author: "") { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<100 {
            controller.view.layoutIfNeeded(); list.layoutIfNeeded()
            if list.visibleCells.contains(where: { $0.accessibilityIdentifier == "moments.pagination.ended" }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(list.visibleCells.map(\.accessibilityIdentifier).contains("moments.pagination.ended"))
        #expect(runtime.pageFailure(author: "") == nil)
        #expect(runtime.posts.map(\.id) == ["first", "second"])
        #expect(!runtime.hasMore(author: ""))
        #expect(!runtime.canLoadNextPage(author: "", retry: true))
        try await runtime.refresh(next: true)
        #expect(await transport.pageCursors.filter { !$0.isEmpty } == ["cursor-1", "cursor-1"])
        #expect(await transport.albumRequests == albums)
        let action = MomentsPendingAction(kind: .like, post: "first", liked: true)
        controller.viewModel.submit(action)
        controller.viewModel.submit(action)
        #expect(controller.viewModel.state.busy == ["first"])
        for _ in 0..<200 {
            if controller.viewModel.state.busy.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.viewModel.state.busy.isEmpty)
        #expect(await transport.likeRequests == 1)
        await runtime.stop().value
        #expect(runtime.loadingPageAuthor == nil && runtime.pageFailure(author: "") == nil)
    }

    @Test func lostResponseReconcilesWithoutCreatingAnotherPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = MomentsTestTransport(), keys = MemorySecureValues(), credentials = try sampleCredentials()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let repository = UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID)
        try repository.save(AccountProfile(userID: credentials.userID, accountName: "fictional_user", nickname: "Fixture", bio: "", version: 1))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)), store: credentialStore, repository: repository)
        await session.restore(); try #require(!session.readOnly)
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("main.sqlite"), key: Data(repeating: 41, count: 32), environment: credentials.environmentID, userID: credentials.userID, migrations: [MomentsStore.migration])
        let media = try EncryptedMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 42, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let chat = ChatRuntime(session: session), runtime = chat.moments
        try runtime.attach(database: database, media: media)
        var draft = MomentsDraft(); draft.text = "preserve original publication"
        try await runtime.save(draft)
        let model = MomentsComposerViewModel(runtime: runtime, draft: draft)
        model.publish()
        for _ in 0..<200 {
            if !model.state.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!model.state.busy && model.state.errorKey != nil)
        #expect(model.state.frozen && model.state.draft.id == draft.id)
        let store = try #require(runtime.store)
        let saved = try #require(try await store.drafts().first)
        #expect(saved.publication != nil && saved.text == draft.text)
        let attempts = await transport.publications.count
        #expect(attempts > 0)
        var finished = false
        model.didFinish = { finished = true }
        model.publish()
        for _ in 0..<200 {
            if finished { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(finished)
        #expect(await transport.publications.count == attempts)
        #expect(try await store.drafts().isEmpty)
        #expect(runtime.posts.count == 1 && runtime.posts[0].text == draft.text)
        let secondChat = ChatRuntime(session: session)
        let sameDraft = MomentsDraft()
        #expect(runtime.claim(sameDraft))
        #expect(!secondChat.moments.claim(sameDraft))
        runtime.release(sameDraft.id)
        #expect(secondChat.moments.claim(sameDraft))
        secondChat.moments.release(sameDraft.id)
        await runtime.stop().value; try database.close()
    }
}
