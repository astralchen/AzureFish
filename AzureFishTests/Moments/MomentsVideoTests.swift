import AVFoundation
import AzureFishAPI
import AzureFishChat
import AzureFishMoments
import AzureFishStorage
import Foundation
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite("朋友圈视频客户端", .serialized)
/// 检查旧快照解码兼容、视频加密草稿重开和封面显示尺寸。
struct MomentsVideoTests {
    @Test func legacyDraftAndPostRemainDecodable() throws {
        let old = MomentsDraft()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "video")
        #expect(try JSONDecoder().decode(MomentsDraft.self, from: JSONSerialization.data(withJSONObject: json)).video == nil)
        let post = MomentsPreviewData.posts[0]
        var snapshot = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(post)) as? [String: Any])
        snapshot.removeValue(forKey: "video")
        #expect(try JSONDecoder().decode(MomentsPost.self, from: JSONSerialization.data(withJSONObject: snapshot)).images == post.images)
    }
    @Test func exportAndEncryptedDraftSurviveReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID(), key = Data(repeating: 32, count: 32)
        let owner = try await AccountBusinessStorage.acquire(root: root, databaseKey: key, mediaKey: key, environment: "video-test", userID: user)
        let store = try MomentsStore(database: owner.resources.database), media = owner.resources.media
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let source = bundle.appendingPathComponent("preview-video-01.mp4")
        let exported = try await media.temporaryFile(filename: "export.mp4"), poster = try await media.temporaryFile(filename: "poster.jpg")
        let metadata = try await MomentsVideoProcessor.export(source, to: exported, poster: poster) { _ in }
        #expect(metadata.duration > 0 && metadata.duration <= 60_000)
        #expect(max(metadata.width, metadata.height) <= 1920 && min(metadata.width, metadata.height) <= 1080)
        #expect(UIImage(contentsOfFile: poster.path) != nil)
        let encrypted = try await media.importFile(exported, filename: "video.mp4", mime: "video/mp4")
        var draft = MomentsDraft(); draft.video = MomentsVideoDraft(source: .init(id: encrypted.id, descriptor: encrypted.input))
        draft.video?.output = .init(id: encrypted.id, descriptor: encrypted.input)
        draft.publication = try MomentsAPI.publication(id: draft.id, operation: draft.operation, text: "", assets: [], video: UUID().uuidString)
        try await store.save(draft)
        #expect(try await !media.removeIfUnreferenced(encrypted.id, database: owner.resources.database))
        let lease = try await media.lease(encrypted.id)
        #expect(FileManager.default.fileExists(atPath: lease.path))
        try await media.release(lease)
        #expect(!FileManager.default.fileExists(atPath: lease.path))
        try await media.release(exported); try await media.release(poster)
        await store.close()
        let reopened = try MomentsStore(database: owner.resources.database)
        let restored = try #require(try await reopened.drafts().first)
        #expect(restored.video?.output?.id == encrypted.id && restored.publication == draft.publication)
        try await reopened.removeDraft(draft.id); try await reopened.recoverCleanup(media: media)
        await #expect(throws: (any Error).self) { try await media.lease(encrypted.id) }
        await reopened.close(); try await owner.release()
    }
    @Test func videoPosterKeepsWidthAndCachedImage() async throws {
        var post = MomentsPreviewData.posts[0]
        var video = try #require(post.images.first); video.kind = "video"; video.width = 1080; video.height = 1920; video.duration = 59_000
        post.images = []; post.video = video
        let runtime = MomentsRuntime(preview: [post], user: post.author.id)
        let image = UIImage(systemName: "video.fill")!
        runtime.cacheThumbnail(image, asset: video, target: post.id)
        var selected = false
        func configuration(_ width: CGFloat) -> MomentsPostConfiguration {
            .init(post: post, media: MomentsMediaProvider(runtime: runtime), width: width, expanded: false, action: { if case .photo = $0 { selected = true } })
        }
        let view = MomentsPostContentView(configuration: configuration(1200))
        func buttons(_ view: UIView) -> [UIButton] { (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        for width in [CGFloat(320), 1200, 390] {
            view.configuration = configuration(width); view.frame = CGRect(x: 0, y: 0, width: width, height: 1400); view.layoutIfNeeded()
            let button = try #require(buttons(view).first { $0.accessibilityIdentifier?.hasPrefix("moments.photo.") == true })
            #expect(button.bounds.width <= 280 && button.bounds.height <= 360)
            #expect(button.image(for: .normal) === image)
            button.sendActions(for: .touchUpInside)
        }
        #expect(selected)
        await runtime.stop().value
        #expect(runtime.cachedThumbnail(video, target: post.id) == nil)
    }
}
