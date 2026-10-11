import AzureFishAPI
import AzureFishChat
import AzureFishMoments
import AzureFishStorage
import Foundation
import Testing
import UIKit
@testable import AzureFish

/// 只有显式启用且已启动独立虚构账号服务时运行；不读取用户安装中的凭据。
@MainActor
@Suite("朋友圈隔离回环联调", .enabled(if: ProcessInfo.processInfo.environment["AZUREFISH_MOMENTS_LIVE"] == "1"))
struct MomentsLiveTests {
    @Test func nineImagesInteractionsCoverAndDeletion() async throws {
        let api = AccountAPI(environment: try .localTesting())
        let registration = try api.prepareRegistration(deviceID: UUID(), accountName: "moments_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12), password: "Fictional-Test-Password-123", nickname: "Moments fixture")
        let account = try await api.execute(registration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = MemorySecureValues(), credentials = account.credentials
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let repository = UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID)
        try repository.save(AccountProfile(account.profile))
        let session = SessionCoordinator(service: LiveAccountService(api: api), store: credentialStore, repository: repository)
        await session.restore(); try #require(!session.readOnly)
        let database = try ChatStore.openDatabase(url: root.appendingPathComponent("main.sqlite"), key: Data(repeating: 81, count: 32), environment: credentials.environmentID, userID: credentials.userID, migrations: [MomentsStore.migration])
        let media = try EncryptedMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 82, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let chat = ChatRuntime(session: session), runtime = chat.moments
        try runtime.attach(database: database, media: media)
        let moments = try #require(runtime.api)
        var draft = MomentsDraft(); draft.text = "Nine ordered fictional images"
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120))
        for index in 0..<9 {
            let data = renderer.jpegData(withCompressionQuality: 0.9) { context in
                UIColor(hue: CGFloat(index) / 9, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: 70, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 30)])
            }
            draft = try await runtime.work { try await runtime.importImage(data, draft: draft) }
        }
        draft.images.reverse(); try await runtime.save(draft)
        let imageHashes = draft.images.map { $0.descriptor.sha256 }
        try await runtime.work { try await runtime.publish(draft) }
        var post = try #require(try await moments.list().posts.first)
        #expect(post.images.count == 9)
        #expect(post.images.map { $0.resources.first { $0.role == "original" }?.sha256 } == imageHashes.map(Optional.some))
        let preview = try await runtime.work { try await runtime.image(post.images[0], target: post.id) }
        #expect(UIImage(data: preview) != nil)
        let like = MomentsPendingAction(kind: .like, post: post.id, liked: true)
        try await runtime.work { try await runtime.mutate(like); try await runtime.mutate(like) }
        post = try await moments.result(post.id); #expect(post.likes.count == 1)
        let comment = MomentsPendingAction(kind: .comment, post: post.id, text: "First comment")
        try await runtime.work { try await runtime.mutate(comment) }
        let reply = MomentsPendingAction(kind: .comment, post: post.id, text: "Reply", replyTo: runtime.userID)
        try await runtime.work { try await runtime.mutate(reply) }
        post = try await moments.result(post.id); #expect(post.comments.count == 2 && post.comments.last?.replyTo?.id == runtime.userID)
        try await runtime.work { try await runtime.mutate(.init(kind: .deleteComment, post: post.id, comment: comment.comment)) }
        #expect(try await moments.result(post.id).comments.count == 1)
        var cover = MomentsDraft(); cover.isCover = true
        let coverBytes = renderer.jpegData(withCompressionQuality: 0.9) { context in UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 120)) }
        cover = try await runtime.work { try await runtime.importImage(coverBytes, draft: cover, cover: true) }
        try await runtime.work { try await runtime.setCover(cover) }
        let album = try await moments.album(runtime.userID); #expect(album.cover != nil)
        try await runtime.work { try await runtime.mutate(.init(kind: .cover, revision: album.revision)) }
        #expect(try await moments.album(runtime.userID).cover == nil)
        try await runtime.work { try await runtime.mutate(.init(kind: .deletePost, post: post.id)) }
        #expect(try await moments.list().posts.isEmpty)
        #expect(try await moments.result(post.id).deleted)
        #expect(try await runtime.store?.drafts().isEmpty == true)
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let source = bundle.appendingPathComponent("preview-video-01.mp4")
        var videoDraft = try await runtime.work { try await runtime.importVideo(source, draft: MomentsDraft()) }
        let output = try await media.temporaryFile(filename: "video.mp4"), poster = try await media.temporaryFile(filename: "cover.jpg")
        let metadata = try await MomentsVideoProcessor.export(source, to: output, poster: poster) { _ in }
        videoDraft = try await runtime.work { try await runtime.saveVideo(output, poster: poster, duration: metadata.duration, width: metadata.width, height: metadata.height, draft: videoDraft) }
        try await media.release(output); try await media.release(poster)
        try await runtime.work { try await runtime.publish(videoDraft) }
        let videoPost = try await moments.result(videoDraft.id.uuidString.lowercased())
        let video = try #require(videoPost.video)
        #expect(videoPost.images.isEmpty && video.duration == metadata.duration)
        for _ in 0..<2 {
            let lease = try await runtime.work { try await runtime.videoLease(video, target: videoPost.id) { _ in } }
            #expect(FileManager.default.fileExists(atPath: lease.path))
            try await media.release(lease)
            #expect(!FileManager.default.fileExists(atPath: lease.path))
        }
        try await runtime.work { try await runtime.mutate(.init(kind: .deletePost, post: videoPost.id)) }
        await #expect(throws: (any Error).self) { try await runtime.videoLease(video, target: videoPost.id) { _ in } }
        #expect(try await moments.result(videoPost.id).video == nil)
        await runtime.stop().value; try database.close()
    }
}
