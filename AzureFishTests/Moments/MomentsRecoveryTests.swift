import AzureFishAPI
import AzureFishChat
import AzureFishMoments
import AzureFishNetwork
import AzureFishProtocol
import AzureFishStorage
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

/// 在协议边界模拟服务端终态、结果不明和授权续期，所有文件均使用隔离的加密测试库。
private actor MomentsRecoveryTransport: HTTPTransport {
    let account = AccountTestTransport()
    var assetState = "expired"
    var healthyAssetState = "ready"
    var creationOffline = false
    var acceptPublication = false
    var acceptAfterFailure = false
    var acceptedDeleted = false
    var resultOffline = false
    var publications: [MomentPublishRequest] = []
    var creates: [MediaCreateRequest] = []
    var resultQueries = 0
    var statusQueries = 0
    let healthyAsset = UUID().uuidString.lowercased()
    var createdAssets: [String: String] = [:]
    var emptyPages = false
    var cursors: [String] = []
    var payload = Data()
    var grants = 0
    var ranges: [String] = []
    var downloadFailure = "once"
    func configureAsset(_ state: String) { assetState = state }
    func setHealthyAssetState(_ state: String) { healthyAssetState = state }
    func setCreationOffline(_ value: Bool) { creationOffline = value }
    func allowPublication() { acceptPublication = true }
    func reconcileAfterFailure(offline: Bool, deleted: Bool = false) {
        resultOffline = offline; acceptAfterFailure = !offline; acceptedDeleted = deleted
    }
    func configureDownload(_ bytes: Data, failure: String) { payload = bytes; downloadFailure = failure }
    func setDownloadFailure(_ value: String) { downloadFailure = value }
    func enableEmptyPages() { emptyPages = true }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        func response<M: SwiftProtobuf.Message>(_ value: M) throws -> HTTPResponse {
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try value.serializedData())
        }
        func failure(_ code: String, _ status: Int) throws -> HTTPResponse {
            var value = ApiError(); value.code = code
            return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/protobuf"], body: try value.serializedData())
        }
        func post(_ input: MomentPublishRequest) throws -> MomentPost {
            var value = MomentPost(); value.postID = input.postID; value.text = input.text
            value.author.userID = try sampleCredentials().userID.uuidString.lowercased()
            value.revision = 1; value.sequence = 1; value.deleted = acceptedDeleted
            return value
        }
        switch request.url.path {
        case "/v1/moments/publish":
            let input = try MomentPublishRequest(serializedBytes: request.body!)
            publications.append(input)
            if !acceptPublication { return try failure(assetState == "missing" ? "MEDIA_NOT_FOUND" : "MEDIA_NOT_READY", assetState == "missing" ? 404 : 409) }
            var result = MomentMutationResult(); result.post = try post(input); return try response(result)
        case "/v1/moments/result":
            resultQueries += 1
            if !publications.isEmpty {
                if resultOffline { throw URLError(.notConnectedToInternet) }
                if acceptAfterFailure { return try response(post(publications.last!)) }
            }
            return try failure("MOMENT_UNAVAILABLE", 404)
        case "/v1/media/assets/status":
            statusQueries += 1
            let input = try MediaAssetRequest(serializedBytes: request.body!)
            var value = MediaAssetStatus(); value.assetID = input.assetID
            if input.assetID == healthyAsset {
                if healthyAssetState == "offline" { throw URLError(.notConnectedToInternet) }
                if healthyAssetState == "missing" { return try failure("MEDIA_NOT_FOUND", 404) }
                value.state = healthyAssetState
            }
            else if createdAssets.values.contains(input.assetID) { value.state = "ready" }
            else {
                if assetState == "offline" { throw URLError(.notConnectedToInternet) }
                if assetState == "missing" { return try failure("MEDIA_NOT_FOUND", 404) }
                value.state = assetState
            }
            value.asset.assetID = input.assetID; value.asset.kind = "image"
            return try response(value)
        case "/v1/media/assets/create":
            let input = try MediaCreateRequest(serializedBytes: request.body!)
            creates.append(input)
            if creationOffline { throw URLError(.notConnectedToInternet) }
            let replacementAsset = createdAssets[input.operationID] ?? UUID().uuidString.lowercased()
            createdAssets[input.operationID] = replacementAsset
            var value = MediaAssetStatus(); value.assetID = replacementAsset; value.state = "ready"
            value.asset.assetID = replacementAsset; value.asset.kind = creates.last!.kind
            return try response(value)
        case "/v1/media/capabilities":
            var value = MediaCapabilities(); value.processorAvailable = true
            value.momentsVideoMaxDurationMs = 60_000; value.videoMaxBytes = 512 * 1024 * 1024
            return try response(value)
        case "/v1/moments/list":
            var value = MomentsListResponse()
            if emptyPages {
                let input = try MomentsListRequest(serializedBytes: request.body!); cursors.append(input.cursor)
                if input.cursor == "second" {
                    var input = MomentPublishRequest(); input.postID = "visible"; input.text = "after tombstones"
                    value.posts = [try post(input)]
                } else { value.hasMore_p = true; value.nextCursor = input.cursor.isEmpty ? "first" : "second" }
            }
            return try response(value)
        case "/v1/moments/album": return try response(MomentAlbum())
        case "/v1/moments/get": return try response(MomentsGetResponse())
        case "/v1/media/resources/authorize":
            grants += 1
            if grants > 1 && downloadFailure == "denied" { return try failure("MEDIA_NOT_FOUND", 404) }
            let input = try MediaAuthorizeRequest(serializedBytes: request.body!)
            var value = MediaDownloadGrant(); value.resourceID = input.resourceID
            value.token = "fictional-grant-\(grants)"; value.etag = "fixture-etag"
            value.byteCount = Int64(payload.count); value.expiresAtMs = 2_000_000_000_000
            return try response(value)
        default:
            if request.url.path.hasSuffix("/content") {
                let range = try #require(request.headers["Range"]); ranges.append(range)
                let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                let start = bounds[0], end = bounds[1]
                if start > 0 && downloadFailure != "none" {
                    if downloadFailure == "unrelated" { return try failure("MEDIA_GRANT_INVALID", 403) }
                    if downloadFailure != "once" || request.headers["X-Media-Grant"] == "fictional-grant-1" {
                        return try failure("MEDIA_GRANT_EXPIRED", 403)
                    }
                }
                return HTTPResponse(statusCode: 206, headers: ["ETag": "fixture-etag", "Content-Range": "bytes \(start)-\(end)/\(payload.count)"], body: payload.subdata(in: start..<(end + 1)))
            }
            return try await account.send(request)
        }
    }
}

@MainActor
@Suite("朋友圈媒体与空页恢复", .serialized)
struct MomentsRecoveryTests {
    private func withRuntime(_ transport: MomentsRecoveryTransport,
                             body: (MomentsRuntime, EncryptedMediaStore, APISessionManager) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemorySecureValues(), credentials = try sampleCredentials()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let repository = UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID)
        try repository.save(AccountProfile(userID: credentials.userID, accountName: "fictional_user", nickname: "Fixture", bio: "", version: 1))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)), store: credentialStore, repository: repository)
        await session.restore(); try #require(!session.readOnly)
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("main.sqlite"), key: Data(repeating: 41, count: 32), environment: credentials.environmentID, userID: credentials.userID, migrations: [MomentsStore.migration])
        defer { try? database.close() }
        let media = try EncryptedMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 42, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let chat = ChatRuntime(session: session), runtime = chat.moments
        try runtime.attach(database: database, media: media)
        do {
            for _ in 0..<200 {
                if runtime.cursors[""] != nil && !runtime.loading { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try await body(runtime, media, try #require(session.sessionManager))
            await runtime.stop().value
        } catch { await runtime.stop().value; throw error }
    }

    private func frozenDraft(_ runtime: MomentsRuntime, transport: MomentsRecoveryTransport, video: Bool) async throws -> MomentsDraft {
        var value = MomentsDraft(); value.text = "preserved text"
        value = try await runtime.importImage(Data([1, 2, 3, 4]), draft: value)
        value.images[0].assetID = UUID().uuidString.lowercased()
        if video {
            value = try await runtime.importImage(Data([7, 8]), draft: value)
            var clip = MomentsVideoDraft(source: value.images[1]); clip.output = value.images[0]; clip.duration = 1_000
            value.video = clip; value.images = []
        } else {
            value = try await runtime.importImage(Data([5, 6]), draft: value)
            value.images[1].assetID = transport.healthyAsset
        }
        value.publication = try MomentsAPI.publication(id: value.id, operation: value.operation, text: value.text,
            assets: value.images.compactMap(\.assetID), video: value.video?.output?.assetID)
        try await runtime.save(value)
        return value
    }

    @Test(arguments: ["expired", "deleted", "cancelled", "failed", "missing"], [false, true])
    func expiredPublicationCanReuploadWithoutLosingLocalContent(state: String, video: Bool) async throws {
        let transport = MomentsRecoveryTransport(); await transport.configureAsset(state)
        try await withRuntime(transport) { runtime, media, _ in
            let original = try await frozenDraft(runtime, transport: transport, video: video)
            await #expect(throws: (any Error).self) { try await runtime.publish(original) }
            let store = try #require(runtime.store)
            let saved = try #require(try await store.drafts().first)
            #expect(saved.id == original.id && saved.text == original.text && saved.resources == original.resources)
            #expect(saved.publication == nil && saved.operation != original.operation)
            let old = video ? original.video!.output! : original.images[0]
            let fresh = video ? saved.video!.output! : saved.images[0]
            #expect(fresh.assetID == nil)
            #expect(fresh.createOperation != old.createOperation && fresh.completeOperation != old.completeOperation)
            #expect(try await media.read(fresh.id, index: 0) == Data([1, 2, 3, 4]))
            if video {
                #expect(saved.video?.source.id == original.video?.source.id)
                #expect(saved.video?.source.createOperation == original.video?.source.createOperation)
            }
            if !video {
                #expect(saved.images[1].assetID == original.images[1].assetID)
                #expect(saved.images[1].createOperation == original.images[1].createOperation)
            }
            #expect(await transport.resultQueries == 2)
            await transport.allowPublication()
            try await runtime.publish(saved)
            #expect(try await store.drafts().isEmpty)
            #expect(runtime.posts.map(\.id) == [original.id.uuidString.lowercased()])
            let creates = await transport.creates
            #expect(creates.count == 1 && creates.first?.operationID == fresh.createOperation.uuidString.lowercased())
            let publications = await transport.publications
            #expect(publications.count == 2 && publications[0].postID == publications[1].postID)
            #expect(publications[0] != publications[1])
        }
    }

    @Test(arguments: ["expired", "missing"], [false, true])
    func unfrozenDraftRecoversWhenMediaExpiresAgain(state: String, video: Bool) async throws {
        let transport = MomentsRecoveryTransport()
        try await withRuntime(transport) { runtime, media, _ in
            let original = try await frozenDraft(runtime, transport: transport, video: video)
            await #expect(throws: (any Error).self) { try await runtime.publish(original) }
            let store = try #require(runtime.store)
            var recovered = try #require(try await store.drafts().first)
            try #require(recovered.publication == nil)
            if video {
                // 模拟解冻后已重新登记视频、但上传中断而尚未冻结发布请求的持久化状态。
                recovered.video?.output?.assetID = transport.healthyAsset
                try await runtime.save(recovered)
            }
            let oldMedia = video ? recovered.video!.output! : recovered.images[1]
            try #require(oldMedia.assetID == transport.healthyAsset)
            await transport.setHealthyAssetState(state)
            await transport.setCreationOffline(true)
            await #expect(throws: (any Error).self) { try await runtime.publish(recovered) }
            let saved = try #require(try await store.drafts().first)
            let fresh = video ? saved.video!.output! : saved.images[1]
            #expect(saved.publication == nil && saved.id == original.id && saved.text == original.text)
            #expect(saved.resources == original.resources && fresh.descriptor == oldMedia.descriptor)
            #expect(fresh.assetID == nil)
            #expect(fresh.createOperation != oldMedia.createOperation && fresh.completeOperation != oldMedia.completeOperation)
            #expect(try await media.read(fresh.id, index: 0) == (video ? Data([1, 2, 3, 4]) : Data([5, 6])))
            if video {
                #expect(saved.video?.source.createOperation == recovered.video?.source.createOperation)
            } else {
                #expect(saved.images[0].createOperation == recovered.images[0].createOperation)
                #expect(saved.images[0].completeOperation == recovered.images[0].completeOperation)
            }
            #expect(await transport.publications.count == 1)
            // 从落盘状态继续；失败的创建请求也必须复用已保存的新操作身份。
            await transport.setCreationOffline(false)
            await transport.allowPublication()
            try await runtime.publish(saved)
            #expect(try await store.drafts().isEmpty)
            let creations = await transport.creates
            let expected = Set((video ? [fresh] : saved.images).map { $0.createOperation.uuidString.lowercased() })
            #expect(Set(creations.map(\.operationID)) == expected)
            #expect(await transport.createdAssets.count == (video ? 1 : 2))
            let sent = try #require(await transport.publications.last)
            #expect(sent.postID == original.id.uuidString.lowercased() && sent.text == original.text)
            let assets = await transport.createdAssets
            if video { #expect(sent.videoAssetID == assets[fresh.createOperation.uuidString.lowercased()]) }
            else { #expect(sent.assetIds == saved.images.compactMap { assets[$0.createOperation.uuidString.lowercased()] }) }
            #expect(await transport.publications.count == 2)
        }
    }

    @Test func unfrozenDraftKeepsUploadIdentityWhenStatusIsUnknown() async throws {
        let transport = MomentsRecoveryTransport()
        try await withRuntime(transport) { runtime, _, _ in
            let original = try await frozenDraft(runtime, transport: transport, video: false)
            await #expect(throws: (any Error).self) { try await runtime.publish(original) }
            let store = try #require(runtime.store)
            let recovered = try #require(try await store.drafts().first)
            await transport.setHealthyAssetState("offline")
            await #expect(throws: (any Error).self) { try await runtime.publish(recovered) }
            let saved = try #require(try await store.drafts().first)
            #expect(saved.images[1].assetID == recovered.images[1].assetID)
            #expect(saved.images[1].createOperation == recovered.images[1].createOperation)
            #expect(saved.images[1].completeOperation == recovered.images[1].completeOperation)
            #expect(saved.operation == recovered.operation && saved.publication == nil)
            #expect(saved.images[0].assetID == recovered.images[0].assetID)
            #expect(await transport.creates.isEmpty)
        }
    }

    @Test(arguments: ["offline", "processing", "ready", "result-offline"])
    func uncertainPublicationRemainsFrozen(state: String) async throws {
        let transport = MomentsRecoveryTransport(); await transport.configureAsset(state)
        if state == "result-offline" { await transport.reconcileAfterFailure(offline: true) }
        try await withRuntime(transport) { runtime, _, _ in
            let draft = try await frozenDraft(runtime, transport: transport, video: false)
            await #expect(throws: (any Error).self) { try await runtime.publish(draft) }
            let store = try #require(runtime.store), saved = try #require(try await store.drafts().first)
            #expect(saved.publication == draft.publication && saved.operation == draft.operation)
            #expect(saved.images[0].assetID == draft.images[0].assetID)
            #expect(saved.images[0].createOperation == draft.images[0].createOperation)
            await #expect(throws: (any Error).self) { try await runtime.discard(saved) }
            #expect(await transport.creates.isEmpty)
        }
    }

    @Test(arguments: [false, true]) func acceptedResultAfterMediaRejectionFinishesOriginalPost(deleted: Bool) async throws {
        let transport = MomentsRecoveryTransport(); await transport.reconcileAfterFailure(offline: false, deleted: deleted)
        try await withRuntime(transport) { runtime, _, _ in
            let draft = try await frozenDraft(runtime, transport: transport, video: false)
            try await runtime.publish(draft)
            let store = try #require(runtime.store)
            #expect(try await store.drafts().isEmpty)
            #expect(runtime.posts.map(\.id) == (deleted ? [] : [draft.id.uuidString.lowercased()]))
            #expect(await transport.statusQueries == 0)
            #expect(await transport.creates.isEmpty)
        }
    }

    @Test func consecutiveEmptyPagesAdvanceUntilVisiblePostAndStopAtEnd() async throws {
        let transport = MomentsRecoveryTransport(); await transport.enableEmptyPages()
        try await withRuntime(transport) { runtime, _, _ in
            #expect(runtime.posts.isEmpty)
            let controller = MomentsViewController(runtime: runtime)
            let window = try makeVisibleTestWindow(rootViewController: controller, size: CGSize(width: 390, height: 400))
            defer { window.isHidden = true; window.rootViewController = nil }
            for _ in 0..<300 {
                controller.view.layoutIfNeeded(); controller.feedView.list.layoutIfNeeded()
                if runtime.posts.contains(where: { $0.id == "visible" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(runtime.posts.map(\.id) == ["visible"])
            #expect(!runtime.hasMore(author: ""))
            let cursors = await transport.cursors
            #expect(Array(cursors.suffix(2)) == ["first", "second"])
            for _ in 0..<10 { controller.feedView.loadNextPageIfNeeded() }
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(await transport.cursors == cursors)
        }
    }

    @Test(arguments: ["once", "always", "unrelated", "denied"])
    func downloadRenewsOnlyExpiredGrantAndResumesSameChunk(failure: String) async throws {
        let transport = MomentsRecoveryTransport()
        let bytes = Data(repeating: 37, count: EncryptedMediaStore.chunkBytes + 7)
        await transport.configureDownload(bytes, failure: failure)
        try await withRuntime(transport) { runtime, media, manager in
            let id = UUID(), target = UUID().uuidString.lowercased()
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let resource = ChatResource(id: id.uuidString.lowercased(), role: "original", filename: "fixture.mp4", mime: "video/mp4", bytes: Int64(bytes.count), sha256: hash)
            let asset = ChatAsset(id: UUID().uuidString.lowercased(), kind: "video", resources: [resource], width: 1, height: 1, duration: 1_000, animated: false, waveform: [], version: 1)
            let author = ChatUser(id: try sampleCredentials().userID.uuidString.lowercased(), nickname: "Fixture", version: 1, avatarID: nil, deleted: false)
            let store = try #require(runtime.store)
            try await store.merge([MomentsPost(id: target, author: author, text: "", video: asset, createdAt: 1)])
            let transfer = MomentsTransfer(store: store, media: media, api: MediaAPI(session: manager, transport: transport))
            if failure == "once" { #expect(try await transfer.download(resource, target: target, offline: false) == id) }
            else { await #expect(throws: (any Error).self) { _ = try await transfer.download(resource, target: target, offline: false) } }
            let first = "bytes=0-\(EncryptedMediaStore.chunkBytes - 1)"
            let second = "bytes=\(EncryptedMediaStore.chunkBytes)-\(bytes.count - 1)"
            #expect(await transport.ranges == (["once", "always"].contains(failure) ? [first, second, second] : [first, second]))
            #expect(await transport.grants == (failure == "unrelated" ? 1 : 2))
            if failure != "once" {
                #expect(try await media.completed(id) == [0])
                await transport.setDownloadFailure("none")
                #expect(try await transfer.download(resource, target: target, offline: false) == id)
                #expect(await transport.ranges.filter { $0 == first }.count == 1)
            }
            try await media.verify(id)
            let recovered = try await media.read(id, index: 0) + media.read(id, index: 1)
            #expect(recovered == bytes)
        }
    }
}
