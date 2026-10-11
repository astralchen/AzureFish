import AVKit
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import QuickLayout
import QuickLayoutKit
import UIKit

/// 在完整加密下载后播放单段视频，关闭和失权时停止播放并释放明文租约。
final class MomentsVideoViewController: LocalizedQuickLayoutHostingController {
    private let runtime: MomentsRuntime
    private let post: MomentsPost?
    private let local: MomentsVideoDraft?
    private let playerController = AVPlayerViewController()
    private let cover = UIImageView()
    private let closeButton = UIButton(type: .close)
    private let retry = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .default)
    private let loading = UIActivityIndicatorView(style: .large)
    private var task: Task<Void, Never>?
    private var observation: UUID?
    private var backgroundObservation: (any NSObjectProtocol)?
    private var lease: URL?
    private var storage: EncryptedMediaStore?
    private let audioSession = SystemAudioSessionController()
    private var audioActive = false
    private var failed = false
    private var readyObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    init(runtime: MomentsRuntime, post: MomentsPost? = nil, local: MomentsVideoDraft? = nil) {
        self.runtime = runtime; self.post = post; self.local = local
        super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        ZStack {
            playerController.view.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            cover.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                loading.frame(width: 44, height: 44)
                progress.resizable(axis: .horizontal).frame(width: min(240, max(1, view.bounds.width - 64)))
                if failed { retry.frame(minWidth: 100, minHeight: 44) }
            }
            VStack {
                HStack { Spacer(); closeButton.frame(width: 44, height: 44) }.frame(maxWidth: .infinity)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(16).safeAreaPadding(.all, 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black; overrideUserInterfaceStyle = .dark
        addChild(playerController); playerController.didMove(toParent: self)
        playerController.allowsPictureInPicturePlayback = false
        playerController.showsPlaybackControls = false
        view.accessibilityIdentifier = "moments.video"
        cover.contentMode = .scaleAspectFit; cover.isUserInteractionEnabled = false
        if let post, let video = post.video { cover.image = runtime.cachedThumbnail(video, target: post.id) }
        closeButton.addAction(UIAction { [weak self] _ in self?.stop(); self?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }, for: .touchUpInside)
        closeButton.accessibilityIdentifier = "moments.video.close"
        retry.addAction(UIAction { [weak self] _ in self?.loadVideo() }, for: .touchUpInside)
        retry.accessibilityIdentifier = "moments.video.retry"
        observation = runtime.observe { [weak self] in
            guard let self else { return }
            if !runtime.ready || (post != nil && !(post?.video.map { runtime.referencesImage($0, target: post!.id, cover: false) } ?? false)) {
                stop(); cover.image = nil; dismiss(animated: false)
            }
        }
        backgroundObservation = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playerController.player?.pause() }
        }
        reloadLocalizedContent(); loadVideo()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); closeButton.accessibilityLabel = Localization.text("common.close")
        retry.setTitle(Localization.text("moments.retry"), for: .normal)
        progress.accessibilityLabel = Localization.text("moments.videoLoading")
        progress.accessibilityIdentifier = "moments.video.progress"
        setNeedsQuickLayout()
    }
    /// 停止上一轮播放，取得完整媒体租约后创建播放器；首帧可显示前保留封面。
    private func loadVideo() {
        let poster = cover.image; stop(); cover.image = poster; failed = false; cover.isHidden = false; progress.isHidden = false; progress.progress = 0
        loading.startAnimating(); updatePlaybackControls(ready: false); setNeedsQuickLayout()
        task = Task { [weak self] in
            guard let self, let media = runtime.media else { return }
            storage = media
            do {
                let url = try await runtime.work { [self] in
                    if let post, let video = post.video {
                        if cover.image == nil, let bytes = try? await runtime.image(video, target: post.id) { cover.image = UIImage(data: bytes) }
                        let url = try await runtime.videoLease(video, target: post.id) { [weak self] value in
                            await MainActor.run { self?.progress.progress = Float(value) }
                        }
                        lease = url; return url
                    }
                    guard let local, let output = local.output else { throw APIClientError.invalidRequest }
                    if let poster = local.poster { cover.image = UIImage(data: try await runtime.localImage(poster)) }
                    let url = try await media.lease(output.id); lease = url; return url
                }
                // 等待下载或解密期间可能切换账号，旧存储的租约不能交给当前播放器。
                guard !Task.isCancelled, runtime.media === media else { try? await media.release(url); return }
                lease = url
                let player = AVPlayer(url: url); player.allowsExternalPlayback = false
                audioActive = true
                try await audioSession.activatePreviewPlayback()
                try Task.checkCancellation()
                playerController.player = player
                readyObservation = playerController.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard self?.playerController.isReadyForDisplay == true else { return }
                        self?.cover.isHidden = true; self?.loading.stopAnimating(); self?.progress.isHidden = true
                        self?.updatePlaybackControls(ready: true); self?.setNeedsQuickLayout()
                    }
                }
                itemObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        self?.failed = true; self?.loading.stopAnimating(); self?.progress.isHidden = true
                        self?.updatePlaybackControls(ready: false); self?.setNeedsQuickLayout()
                    }
                }
                if UIApplication.shared.applicationState == .active { player.play() }
            } catch is CancellationError { stop() } catch {
                failed = true; loading.stopAnimating(); progress.isHidden = true; updatePlaybackControls(ready: false); setNeedsQuickLayout()
            }
        }
    }
    private func updatePlaybackControls(ready: Bool) {
        // 加载／失败由页面提供退出入口；播放就绪后只保留 AVKit 的系统关闭控件。
        closeButton.isHidden = ready
        playerController.showsPlaybackControls = ready
    }
    /// 取消加载、断开播放器和音频会话，再异步归还明文文件租约。
    private func stop() {
        task?.cancel(); task = nil; readyObservation = nil; itemObservation = nil; playerController.player?.pause(); playerController.player?.replaceCurrentItem(with: nil)
        if audioActive { audioSession.deactivate(); audioActive = false }
        playerController.player = nil; cover.image = nil; loading.stopAnimating()
        if let lease, let storage { Task { try? await storage.release(lease) } }; lease = nil
    }
    override func accessibilityPerformEscape() -> Bool { stop(); dismiss(animated: !UIAccessibility.isReduceMotionEnabled); return true }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); stop() }
    isolated deinit {
        task?.cancel(); if audioActive { audioSession.deactivate() }; if let observation { runtime.remove(observation) }
        if let backgroundObservation { NotificationCenter.default.removeObserver(backgroundObservation) }
        if let lease, let storage { Task { try? await storage.release(lease) } }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈视频播放器") { MomentsVideoViewController(runtime: MomentsPreviewData.runtime()) }
#endif
