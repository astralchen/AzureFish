import AppLocalization
import AVFoundation
import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import UIKit

/// 全屏短视频列表；只将当前页交给一个播放器，离开时归还全部临时媒体。
final class ShortVideoViewController: LocalizedQuickLayoutHostingController, UIScrollViewDelegate, UIAdaptivePresentationControllerDelegate {
    let runtime: ShortVideoRuntime
    let feedView = ShortVideoFeedView()
    let controlsView = ShortVideoControlsView()
    let viewModel: ShortVideoViewModel
    var muted = true
    var positions: [String: Double] = [:]
    var commentModels: [String: ShortVideoCommentsViewModel] = [:]
    var state = ShortVideoPlaybackState()
    var player: AVPlayer?
    var observation: NSKeyValueObservation?
    var timeObserver: Any?
    var endObserver: (any NSObjectProtocol)?
    var notifications: [any NSObjectProtocol] = []
    var stopObserver: UUID?
    var loadTask: Task<Void, Never>?
    var resource: UUID?
    let audio = SystemAudioSessionController()
    /// audioActive 包含已排队的激活；audioReady 仅在系统确认后允许恢复声音。
    var audioActive = false
    var audioReady = false
    var restoration = UUID()
    var previousSize = CGSize.zero
    var current: ShortVideoItem? { viewModel.current }
    init(runtime: ShortVideoRuntime) { self.runtime = runtime; self.viewModel = ShortVideoViewModel(runtime: runtime); super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "shortVideo.title" }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var body: Layout {
        ZStack(alignment: .bottom) {
            feedView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            controlsView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        feedView.scrollDelegate = self
        navigationItem.largeTitleDisplayMode = .never
        view.accessibilityIdentifier = "shortVideo.feed"
        viewModel.changed = { [weak self] in self?.render() }
        viewModel.pageLoaded = { [weak self] in
            guard let self else { return }
            feedView.apply(viewModel.items)
            if player == nil && loadTask == nil { loadCurrent() }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePlay))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapLike))
        doubleTap.numberOfTapsRequired = 2; tap.require(toFail: doubleTap)
        feedView.list.addGestureRecognizer(tap); feedView.list.addGestureRecognizer(doubleTap)
        controlsView.back.addAction(UIAction { [weak self] _ in self?.navigationController?.popViewController(animated: true) }, for: .touchUpInside)
        controlsView.play.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .touchUpInside)
        controlsView.mute.addAction(UIAction { [weak self] _ in guard let self else { return }; muted.toggle(); player?.isMuted = muted; render() }, for: .touchUpInside)
        controlsView.like.addAction(UIAction { [weak self] _ in self?.likeVideo() }, for: .touchUpInside)
        controlsView.comments.addAction(UIAction { [weak self] _ in self?.openComments() }, for: .touchUpInside)
        controlsView.share.addAction(UIAction { [weak self] _ in self?.shareVideo() }, for: .touchUpInside)
        controlsView.source.addAction(UIAction { [weak self] _ in self?.openSource() }, for: .touchUpInside)
        feedView.retry.addAction(UIAction { [weak self] _ in
            guard let self else { return }; viewModel.errorKey = nil
            if viewModel.hasPendingLike { viewModel.setLike() }
            else if current == nil || player != nil { viewModel.loadNextPage() } else { loadCurrent() }
        }, for: .touchUpInside)
        controlsView.seek.addAction(UIAction { [weak self] _ in self?.player?.pause() }, for: .touchDown)
        controlsView.seek.addAction(UIAction { [weak self] _ in self?.seekVideo() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        controlsView.seek.addAction(UIAction { [weak self] _ in
            guard let self, !controlsView.seek.isTracking else { return }; seekVideo()
        }, for: .valueChanged)
        stopObserver = runtime.observeStop { [weak self] in
            guard let self else { return }; state.visible = false; unload()
            commentModels = [:]; positions = [:]; feedView.apply([]); render()
        }
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let routeLost = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if name == AVAudioSession.routeChangeNotification && !routeLost { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if name == UIApplication.willResignActiveNotification { state.foreground = false; state.scrolling = false }
                    else { state.paused = true }
                    unload(); render()
                }
            })
        }
        notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }; state.foreground = true
                if state.visible && !state.obscured { restorePlayback(); refreshCurrent() }
            }
        })
        reloadLocalizedContent()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        configureHeader()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); state.visible = true; state.foreground = UIApplication.shared.applicationState == .active
        if viewModel.items.isEmpty { viewModel.loadNextPage() } else { restorePlayback(); refreshCurrent() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); state.visible = false; state.scrolling = false
        if !state.obscured { navigationController?.setNavigationBarHidden(false, animated: animated) }
        if state.obscured { player?.pause() } else { unload() }
        viewModel.cancelRequests()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard feedView.list.bounds.size != previousSize, feedView.list.bounds.height > 0 else { return }
        previousSize = feedView.list.bounds.size; feedView.list.collectionViewLayout.invalidateLayout()
        feedView.list.setContentOffset(CGPoint(x: 0, y: CGFloat(viewModel.index) * feedView.list.bounds.height), animated: false)
        feedView.list.layoutIfNeeded(); currentCell()?.playerLayer.player = player
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }
        configureHeader()
        render()
    }
    private func configureHeader() {
        let information = UIAction(title: Localization.text("shortVideo.about"), image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.showInformation()
        }
        controlsView.configureHeader(showsBack: navigationController?.viewControllers.first !== self,
            menu: UIMenu(children: [information, Localization.languageMenu()]))
    }
    func render() {
        controlsView.render(item: current, paused: state.paused, muted: muted, mutating: viewModel.mutating,
            ready: player?.currentItem?.status == .readyToPlay)
        feedView.renderStatus(errorKey: viewModel.errorKey,
            empty: viewModel.items.isEmpty && !viewModel.fetching, hasMore: viewModel.more)
        if viewModel.fetching { feedView.loading.startAnimating() }
        else if loadTask == nil && (player == nil || player?.currentItem?.status == .readyToPlay) { feedView.loading.stopAnimating() }
    }
    isolated deinit {
        loadTask?.cancel()
        if let stopObserver { runtime.remove(stopObserver) }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause(); if audioActive { audio.deactivate() }
        if let resource { Task { [runtime] in await runtime.release(resource) } }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频空状态") { AppNavigationController(rootViewController: ShortVideoViewController(runtime: ShortVideoRuntime())) }
#endif
