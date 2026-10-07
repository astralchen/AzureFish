import AzureFishAPI
import AzureFishChat
import AzureFishStorage
import AzureFishNetwork
import AzureFishProtocol
import CryptoKit
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

private actor RemoteMediaSessionStore: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

private actor RemotePreviewTransport: HTTPTransport {
    let resources: [String: (ChatResource, Data)]
    var downloaded: [String] = []
    init(_ resources: [String: (ChatResource, Data)]) { self.resources = resources }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("/authorize") {
            let input = try MediaAuthorizeRequest(serializedBytes: request.body ?? Data())
            guard let (resource, _) = resources[input.resourceID] else { throw NetworkError.invalidRequest }
            var grant = MediaDownloadGrant()
            grant.resourceID = resource.id; grant.etag = resource.sha256
            grant.token = "fictional-preview-grant"; grant.byteCount = resource.bytes
            grant.expiresAtMs = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
            return .init(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try grant.serializedData())
        }
        let id = request.url.deletingLastPathComponent().lastPathComponent
        guard request.url.path.hasSuffix("/content"), let (resource, bytes) = resources[id] else { throw NetworkError.invalidRequest }
        downloaded.append(id)
        return .init(statusCode: 206, headers: ["ETag": resource.sha256,
            "Content-Range": "bytes 0-\(bytes.count - 1)/\(bytes.count)"], body: bytes)
    }
}

@Suite("远程媒体展示与运行时释放", .serialized)
@MainActor
struct ChatRemoteMediaTests {
    @Test func remoteMetadataHasGeometryWithoutLocalOriginalAndCannotBecomeDraft() async throws {
        guard #available(iOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 84, count: 32), environment: "remote-test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 85, count: 32), environment: "remote-test", userID: user)
        let environment = try APIEnvironment(identifier: "remote-test", baseURL: URL(string: "https://example.invalid")!)
        let engine = ChatEngine(store: store, session: APISessionManager(api: AccountAPI(environment: environment), store: RemoteMediaSessionStore()))
        let conversation = ConversationPreviewData.detailsConversation()
        let runtime = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: [conversation], pageLeaseRoot: root.appendingPathComponent("pages"))
        let session = LiveChatSession(runtime: runtime, conversation: conversation)
        let resource = ChatResource(id: UUID().uuidString, role: "original", filename: "movie.mov", mime: "video/quicktime", bytes: 30_000_000, sha256: String(repeating: "0", count: 64))
        let asset = ChatAsset(id: UUID().uuidString, kind: "video", resources: [resource], width: 1080, height: 1920,
                             duration: 42000, animated: false, waveform: [], version: 1)
        let message = ChatMessage(id: UUID().uuidString, conversationID: conversation.id, clientID: UUID().uuidString,
            serverID: UUID().uuidString, senderID: user.uuidString, deviceID: UUID().uuidString, sequence: 1,
            createdAt: 1, revision: 1, kind: "media_group", schemaVersion: 1, text: "", textRuns: nil, linkURL: nil,
            revoked: false, receipt: .init(expected: 1, delivered: 0, read: 0, revision: 1), assets: [asset], systemEvent: nil)
        let remote = session.remoteMetadata(message)
        #expect(remote.items.first?.pixelSize == CGSize(width: 1080, height: 1920))
        #expect(remote.items.first?.thumbnailFileURL == nil)
        #expect(Attachment.remote(remote).localFileURLs.isEmpty)
        let presentation = MessagePresentation(id: 1, direction: .incoming, attachment: .remote(remote), deliveryText: nil)
        #expect(presentation.mediaPresentation?.items.count == 1 && presentation.mediaGroup == nil)
        let target = MessageMenuTarget(messageID: 1, attachmentID: remote.id, mediaItemID: remote.items[0].id)
        #expect(target.matches(presentation))
        var draft = ChatDraftSnapshot(conversationID: conversation.id)
        draft.documents = [.remote(remote)]
        #expect(throws: ChatMediaStoreError.invalidResource) { try draft.storageValue() }
        session.stop(); runtime.stop()
    }
    @Test func listDownloadsOnlyThumbnailAndUserPreviewRequestsOriginal() async throws {
        guard #available(iOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 88, count: 32), environment: "preview-test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 89, count: 32), environment: "preview-test", userID: user)
        func resource(_ role: String, size: CGFloat) throws -> (ChatResource, Data) {
            let bytes = try #require(UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            }.pngData())
            return (.init(id: UUID().uuidString.lowercased(), role: role, filename: role + ".png", mime: "image/png", bytes: Int64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()), bytes)
        }
        let (thumbnail, small) = try resource("thumbnail", size: 16)
        let (original, large) = try resource("original", size: 64)
        let transport = RemotePreviewTransport([thumbnail.id: (thumbnail, small), original.id: (original, large)])
        let environment = try APIEnvironment(identifier: "preview-test", baseURL: URL(string: "https://example.invalid")!)
        let manager = APISessionManager(api: AccountAPI(environment: environment, transport: transport), store: RemoteMediaSessionStore())
        let token = try SessionToken(rawValue: String(repeating: "b", count: 43))
        try await manager.install(.init(environmentID: environment.identifier, userID: user, deviceID: UUID(), sessionID: UUID(),
            accessToken: token, accessExpiresAt: Date().addingTimeInterval(3600), refreshToken: token,
            refreshExpiresAt: Date().addingTimeInterval(7200), refreshGeneration: 1))
        let engine = ChatEngine(store: store, session: manager)
        let queue = ChatTransferQueue(store: store, media: media, session: manager, engine: engine, transport: transport)
        let conversation = ConversationPreviewData.detailsConversation()
        try await store.save(conversation)
        let runtime = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: [conversation],
                                  pageLeaseRoot: root.appendingPathComponent("pages"), transfers: queue)
        let session = LiveChatSession(runtime: runtime, conversation: conversation)
        let asset = ChatAsset(id: UUID().uuidString.lowercased(), kind: "image", resources: [original, thumbnail], width: 64, height: 64,
                             duration: 0, animated: false, waveform: [], version: 1)
        var message = ChatMessage(id: UUID().uuidString.lowercased(), conversationID: conversation.id, clientID: UUID().uuidString,
            serverID: UUID().uuidString, senderID: user.uuidString, deviceID: UUID().uuidString, sequence: 1,
            createdAt: 1, revision: 1, kind: "media_group", schemaVersion: 1, text: "", textRuns: nil, linkURL: nil,
            revoked: false, receipt: .init(expected: 1, delivered: 0, read: 0, revision: 1), assets: [asset], systemEvent: nil)
        try await store.save(message)
        session.messages = [message]
        let id = session.identity(message.id)
        let files = PageAttachmentStore(parentDirectory: root)
        defer { files.removeAll() }
        let listed = try await session.resolvePreview(message, files: files)
        #expect(await transport.downloaded == [thumbnail.id])
        guard case .remote(let remote) = listed else { Issue.record("List must retain remote metadata"); return }
        #expect(remote.items.first?.thumbnailFileURL != nil)
        let opened = try await session.resolveAttachment(listed, messageID: id)
        #expect(await transport.downloaded == [thumbnail.id, original.id])
        guard case .mediaGroup(let group) = opened else { Issue.record("Preview must resolve local original"); return }
        #expect(try Data(contentsOf: group.items[0].originalFileURL) == large)
        message.revoked = true; message.revision = 2
        try await store.save(message)
        await #expect(throws: ChatMediaStoreError.unavailable) { try await session.resolveAttachment(listed, messageID: id) }
        #expect(await transport.downloaded == [thumbnail.id, original.id])
        session.stop(); runtime.stop()
        await queue.stop(); await engine.stop(); try await store.close()
    }

    @Test func finalRuntimeReleaseClosesStoreWithoutRetainingOwner() async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 86, count: 32), environment: "release-test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 87, count: 32), environment: "release-test", userID: user)
        let environment = try APIEnvironment(identifier: "release-test", baseURL: URL(string: "https://example.invalid")!)
        let engine = ChatEngine(store: store, session: APISessionManager(api: AccountAPI(environment: environment), store: RemoteMediaSessionStore()))
        var runtime: ChatRuntime? = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: [], pageLeaseRoot: root.appendingPathComponent("pages"))
        let drafts = try #require(runtime?.originalDraftStore)
        var resume: CheckedContinuation<Void, Never>?
        let work: Task<Void, Error> = drafts.enqueue {
            await withCheckedContinuation { resume = $0 }
            try Task.checkCancellation()
        }
        for _ in 0..<100 {
            if resume != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(resume != nil)
        runtime?.stop()
        weak var released = runtime
        runtime = nil
        #expect(released == nil)
        _ = try await store.messages("none")
        resume?.resume()
        do { try await work.value; Issue.record("Ended draft operation succeeded") }
        catch { #expect(error is CancellationError) }
        for _ in 0..<100 {
            if released == nil, (try? await store.checkpoint()) == nil {
                do { _ = try await store.messages("none"); }
                catch ChatStoreError.unavailable { return }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(released == nil)
        Issue.record("Runtime finalization did not close its owned store")
    }
}
