#if DEBUG
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import CryptoKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 确定性虚构视频入口，真实走账号加密文件与播放器，不访问用户账号或相册。
final class MomentsVideoDemoController: LocalizedQuickLayoutHostingController {
    private let status = UILabel()
    private var owner: AccountBusinessStorage?
    private var runtime: MomentsRuntime?
    private var task: Task<Void, Never>?
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("moments-video-demo-" + UUID().uuidString)
    override var body: Layout { status.resizable(axis: .horizontal).frame(maxWidth: .infinity).padding(24) }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground; status.text = Localization.text("moments.videoLoading"); status.numberOfLines = 0
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var protectedRoot = root; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try protectedRoot.setResourceValues(flags)
                let user = UUID()
                let databaseKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let mediaKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let owner = try await AccountBusinessStorage.acquire(root: root, databaseKey: databaseKey, mediaKey: mediaKey, environment: "moments-video-demo", userID: user)
                self.owner = owner
                let runtime = MomentsRuntime(preview: [], user: user.uuidString.lowercased()); self.runtime = runtime
                try runtime.attach(database: owner.resources.database, media: owner.resources.media)
                guard let bundle = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"), let store = runtime.store else { return }
                let media = owner.resources.media
                var draft = try await runtime.importVideo(bundle.appendingPathComponent("preview-video-01.mp4"), draft: MomentsDraft())
                let output = try await media.temporaryFile(filename: "output.mp4"), poster = try await media.temporaryFile(filename: "poster.jpg")
                let info = try await MomentsVideoProcessor.export(bundle.appendingPathComponent("preview-video-01.mp4"), to: output, poster: poster) { _ in }
                draft = try await runtime.saveVideo(output, poster: poster, duration: info.duration, width: info.width, height: info.height, draft: draft)
                try await media.release(output); try await media.release(poster)
                guard let video = draft.video, let file = video.output, let cover = video.poster else { return }
                let resources = [(file, "original"), (cover, "cover")].map { value, role in
                    ChatResource(id: value.id.uuidString.lowercased(), role: role, filename: value.descriptor.filename, mime: value.descriptor.mime, bytes: value.descriptor.bytes, sha256: value.descriptor.sha256)
                }
                let asset = ChatAsset(id: UUID().uuidString.lowercased(), kind: "video", resources: resources, width: info.width, height: info.height, duration: info.duration, animated: false, waveform: [], version: 1)
                let author = ChatUser(id: user.uuidString.lowercased(), nickname: "Video Fixture", version: 1, avatarID: nil, deleted: false)
                let post = MomentsPost(id: "video-fixture", author: author, text: "Video · 60s", video: asset, createdAt: 1)
                try await store.merge([post]); try await runtime.restore()
                let bytes = try await runtime.localImage(cover)
                if let image = UIImage(data: bytes) { runtime.cacheThumbnail(image, asset: asset, target: post.id) }
                if ProcessInfo.processInfo.arguments.contains("-moments-video-editor") {
                    _ = runtime.claim(draft)
                    navigationController?.pushViewController(MomentsComposerViewController(runtime: runtime, draft: draft), animated: false)
                } else {
                    navigationController?.pushViewController(MomentsViewController(runtime: runtime), animated: false)
                }
            } catch { status.text = Localization.text("moments.failed"); setNeedsQuickLayout() }
        }
    }
    isolated deinit {
        task?.cancel(); let stop = runtime?.stop(), owner = owner, root = root
        Task { await stop?.value; try? await owner?.release(); try? FileManager.default.removeItem(at: root) }
    }
}
@available(iOS 17.0, *)
#Preview("朋友圈视频样例") { AppNavigationController(rootViewController: MomentsVideoDemoController()) }
#endif
