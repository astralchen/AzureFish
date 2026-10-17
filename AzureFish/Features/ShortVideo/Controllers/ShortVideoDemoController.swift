#if DEBUG
import AzureFishAPI
import AzureFishStorage
import CryptoKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 隔离的虚构账号样例，播放器仍经过真实加密存储与明文租约路径。
final class ShortVideoDemoController: LocalizedQuickLayoutHostingController {
    private let status = UILabel()
    private var owner: AccountBusinessStorage?
    private var moments: MomentsRuntime?
    private var runtime: ShortVideoRuntime?
    private var task: Task<Void, Never>?
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("short-video-fixture-" + UUID().uuidString)
    override var body: Layout { status.resizable().frame(maxWidth: .infinity).padding(24) }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                var protectedRoot = root
                var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                try protectedRoot.setResourceValues(flags)
                let user = UUID()
                let owner = try await AccountBusinessStorage.acquire(root: root,
                    databaseKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                    mediaKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "short-video-fixture", userID: user)
                self.owner = owner
                let moments = MomentsRuntime(preview: [], user: user.uuidString.lowercased()); self.moments = moments
                try moments.attach(database: owner.resources.database, media: owner.resources.media)
                guard let bundle = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle") else { throw APIClientError.invalidResponse }
                var items: [ShortVideoItem] = []
                for number in 1...3 {
                    let url = bundle.appendingPathComponent(String(format: "preview-video-%02d.mp4", number))
                    let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    items.append(ShortVideoItem(id: "pixabay:\(number)", author: "Fixture creator \(number)", tags: "本地视频样例 · Local video fixture",
                        sourceURL: "https://pixabay.com/", videoURL: url.absoluteString, thumbnailURL: "", bytes: Int64(count), duration: 12, width: 720, height: 1280))
                }
                let runtime = ShortVideoRuntime(); self.runtime = runtime; runtime.fixtureMoments = moments
                runtime.fixtureAPI = ShortVideoFixtureService(items: items, user: user.uuidString.lowercased())
                runtime.fixtureMedia = { item, thumbnail in
                    try Task.checkCancellation()
                    let url = thumbnail ? bundle.appendingPathComponent("preview-image-08.png") : URL(string: item.videoURL)!
                    return try Data(contentsOf: url)
                }
                let page = ShortVideoViewController(runtime: runtime)
                if ProcessInfo.processInfo.arguments.contains("-short-video-tab-demo") {
                    navigationController?.setViewControllers([page], animated: false)
                } else { navigationController?.pushViewController(page, animated: false) }
            } catch { status.text = Localization.text("shortVideo.failed"); setNeedsQuickLayout() }
        }
    }
    isolated deinit {
        task?.cancel()
        let stopping = runtime?.stop(), moments = moments, owner = owner, root = root
        Task { await stopping?.value; await moments?.stop().value; try? await owner?.release(); try? FileManager.default.removeItem(at: root) }
    }
}
/// 仅 Debug 的确定性业务替身，互动不会写入真实服务端。
actor ShortVideoFixtureService: ShortVideoServing {
    var items: [ShortVideoItem]
    var messages: [String: [VideoComment]] = [:]
    let user: String
    init(items: [ShortVideoItem], user: String) { self.items = items; self.user = user }
    func list(cursor: String) async throws -> ShortVideoPage { .init(videos: items, cursor: "", hasMore: false) }
    func get(_ id: String) async throws -> ShortVideoItem { guard let item = items.first(where: { $0.id == id }) else { throw APIClientError.invalidResponse }; return item }
    func like(_ id: String, liked: Bool, operation: UUID) async throws -> ShortVideoItem {
        let index = items.firstIndex { $0.id == id }!; items[index].liked = liked; items[index].likeCount = liked ? 1 : 0; return items[index]
    }
    func comments(_ id: String, cursor: String) async throws -> VideoCommentsPage { .init(comments: messages[id] ?? [], cursor: "", hasMore: false) }
    func comment(_ video: String, id: UUID, text: String, operation: UUID) async throws -> ShortVideoItem {
        if !(messages[video] ?? []).contains(where: { $0.id == id.uuidString }) {
            messages[video, default: []].append(VideoComment(id: id.uuidString, author: ChatUser(id: user, nickname: "Fixture viewer", version: 1, avatarID: nil, deleted: false), text: text, createdAt: 1_800_000_000_000))
        }
        let index = items.firstIndex { $0.id == video }!; items[index].commentCount = Int64(messages[video, default: []].count); return items[index]
    }
    func deleteComment(_ video: String, id: String, operation: UUID) async throws -> ShortVideoItem {
        messages[video]?.removeAll { $0.id == id }
        let index = items.firstIndex { $0.id == video }!; items[index].commentCount = Int64(messages[video, default: []].count); return items[index]
    }
}
@available(iOS 17.0, *)
#Preview("短视频加密播放样例") { AppNavigationController(rootViewController: ShortVideoDemoController()) }
#endif
