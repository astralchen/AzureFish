import AVFoundation
import UIKit
import QuickLayout
import QuickLayoutKit
import ListKit

/// 照片、视频和常用文件共享的全屏玻璃预览容器。
@available(iOS 26.0, *)
final class AttachmentPreviewController: QuickLayoutHostingController, UICollectionViewDelegate, UIGestureRecognizerDelegate, MediaImageLoadingOwner {
    /// 与聊天页面共享的图片调度器和缩略图缓存。
    let mediaImageLoader: MediaImageLoader
    let items: [AttachmentPreviewItem]
    private(set) var currentIndex: Int
    let playback: AttachmentPreviewPlayer
    private let playbackCoordinator: PlaybackCoordinator
    private var livePhotoModes: [UUID: LivePhotoPlaybackMode] = [:]
    let collectionView: UICollectionView
    let backdrop = UIView()
    /// 独立控制层拥有全部预览控件，宿主只连接播放、分页和转场意图。
    private(set) lazy var chrome: AttachmentPreviewControlsView = {
        let controls = AttachmentPreviewControlsView(items: items, selectedIndex: currentIndex, imageLoader: mediaImageLoader)
        controls.didSelectLivePhotoMode = { [weak self] mode in self?.setLivePhotoMode(mode) }
        controls.didRequestClose = { [weak self] in self?.closeTapped() }
        controls.didRequestPlaybackToggle = { [weak self] in self?.playTapped() }
        controls.didRequestMuteToggle = { [weak self] in self?.playback.isMuted.toggle() }
        controls.didBeginSeeking = { [weak self] in self?.playback.beginSeeking() }
        controls.didChangeSeekPosition = { [weak self] fraction, isTracking in
            guard let self else { return }
            playback.seek(fraction: fraction, finished: !isTracking && !playback.isSeeking)
        }
        controls.didEndSeeking = { [weak self] fraction in
            guard let self, playback.isSeeking else { return }
            playback.seek(fraction: fraction, finished: true)
        }
        controls.willRevealControls = { [weak self] in self?.synchronizeThumbnailPosition() }
        controls.didChangeVisibility = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        controls.thumbnailStrip.didSelectItem = { [weak self] index in self?.select(index, animated: true) }
        controls.thumbnailStrip.didBeginScrubbing = { [weak self] in self?.beginThumbnailScrubbing() }
        controls.thumbnailStrip.didScrubToItem = { [weak self] index in self?.select(index, animated: false) }
        controls.thumbnailStrip.didEndScrubbing = { [weak self] index in self?.endThumbnailScrubbing(at: index) }
        return controls
    }()
    private lazy var adapter = CollectionListAdapter<Int>(collectionView: collectionView)

    /// 黑色画布、分页和玻璃控制层共享全屏布局。
    override var body: Layout {
        ZStack {
            backdrop.resizable()
            collectionView.resizable()
            chrome.resizable()
        }
    }
    /// 连续浏览开始时暂停并解除当前输出，经过的中间项目不准备播放器。
    private func beginThumbnailScrubbing() {
        thumbnailScrubbingStartIndex = currentIndex
        isThumbnailScrubbing = true
        suspendOriginals()
        stopHorizontalScrolling()
        playback.stop()
        currentPage?.bind(player: nil)
    }
    /// 停稳后只准备最终项目，是否自动播放由起始索引与最终索引决定。
    private func endThumbnailScrubbing(at index: Int) {
        isThumbnailScrubbing = false
        finishPaging(at: index)
        prepareCurrentPlayback()
        bindCurrentPlayer()
        if index != thumbnailScrubbingStartIndex { autoplayCurrentVideo() }
        thumbnailScrubbingStartIndex = nil
    }
    /// 连续缩略图浏览期间延迟音视频准备，避免经过每项都创建播放器。
    private var isThumbnailScrubbing = false
    /// 记录整次缩略图拖动的起点；中间索引只预览，最终切换到其他视频时才自动播放。
    private var thumbnailScrubbingStartIndex: Int?
    /// 保留主图手势开始前的正式索引，打断旧翻页动画时仍能识别最终是否切换了视频。
    private var pagingStartIndex: Int?
    private var didPosition = false
    private var lastSize = CGSize.zero
    /// 待完成的程序翻页目标；实际当前项仅在停稳后提交。
    private(set) var pendingPageIndex: Int?
    private var isPositioningPage = false
    private var rotationPageIndex: Int?
    private var previousMetrics = AttachmentPagingLayout.Metrics(size: .zero, count: 0)
    let pagingLayout: AttachmentPagingLayout
    private var transitionHandler: AttachmentPreviewTransition!
    private var pan: UIPanGestureRecognizer!
    private var didCompleteDismissal = false
    /// 首次展开完成时仅消费一次自动播放机会，避免取消关闭或返回页面时覆盖手动暂停。
    private var didCompleteInitialAppearance = false
    private var accessibilityObservers: [NSObjectProtocol] = []
    /// 当前项目对应的可见来源，转场发生时重新求值。
    var sourceResolver: ((Int, Bool) -> UIView?)?
    /// 关闭成功后恢复编辑器和辅助功能焦点。
    var didClose: (() -> Void)?

    init(items: [AttachmentPreviewItem], initialIndex: Int, playbackCoordinator: PlaybackCoordinator, imageLoader: MediaImageLoader? = nil) {
        mediaImageLoader = imageLoader ?? MediaImageLoader()
        self.items = items
        currentIndex = AttachmentPreviewPolicy.index(initialIndex, count: items.count)
        self.playbackCoordinator = playbackCoordinator
        playback = AttachmentPreviewPlayer(coordinator: playbackCoordinator)
        let layout = AttachmentPagingLayout()
        pagingLayout = layout
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        modalPresentationCapturesStatusBarAppearance = true
        transitionHandler = AttachmentPreviewTransition(preview: self)
        transitioningDelegate = transitionHandler
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { chrome.prefersStatusBarHidden }
    var currentItem: AttachmentPreviewItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    var currentPage: AttachmentPreviewPage? { collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? AttachmentPreviewPage }

    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "imessage.preview"
        view.accessibilityViewIsModal = true
        backdrop.backgroundColor = .black
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = false
        collectionView.decelerationRate = .fast
        collectionView.alwaysBounceHorizontal = items.count > 1
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        // Preserve the attachment's physical order, matching the existing stack gesture.
        collectionView.semanticContentAttribute = .forceLeftToRight
        playback.didChange = { [weak self] in self?.refreshPlayback() }
        playback.didFail = { [weak self] in self?.currentPage?.showError() }
        pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        for name in [UIAccessibility.reduceTransparencyStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification, UIAccessibility.voiceOverStatusDidChangeNotification] {
            accessibilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAccessibilitySettings() }
            })
        }
        adapter.collectionDelegate = self
        adapter.scrollDelegate = self
        adapter.apply(transaction: .disabled) {
            ListSection(0) {
                ListKit.ForEach(Array(items.enumerated()), id: \.element.id) { entry in
                    Row(entry.element.id, model: entry.element, cell: AttachmentPreviewPage.self) { [weak self] page, item, _ in
                        self?.configure(page, item: item, index: entry.offset)
                    }
                }
            }.selectionMode(.none)
        }
        applyAccessibilitySettings()
        updateCurrentItem()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        if size.width > 0, size.height > 0, !isPositioningPage, lastSize != size || !didPosition {
            let index = rotationPageIndex ?? pendingPageIndex ?? (pagingLayout.dragStartIndex != nil
                ? previousMetrics.index(nearestTo: collectionView.contentOffset) : currentIndex)
            lastSize = size
            didPosition = true
            rotationPageIndex = nil
            stopHorizontalScrolling()
            pagingLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            previousMetrics = pagingLayout.metrics
            finishPaging(at: index)
        }
        chrome.semanticContentAttribute = view.semanticContentAttribute
        chrome.layoutIfNeeded()
        updateOriginalEligibility()
        for case let page as AttachmentPreviewPage in collectionView.visibleCells {
            page.documentTopInset = chrome.documentTopInset
        }
    }

    /// 展开转场完成且视频输出已绑定后启动首个视频，后续出现回调不重复启动。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bindCurrentPlayer()
        updateOriginalEligibility()
        if !didCompleteInitialAppearance {
            didCompleteInitialAppearance = true
            autoplayCurrentVideo()
        }
        UIAccessibility.post(notification: .screenChanged, argument: chrome.closeButton)
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); currentPage?.stopLivePhotoPlayback(); if isBeingDismissed { completeDismissal() } }

    /// 仅在成功关闭后清理；交互式取消不能销毁播放状态。
    func completeDismissal() {
        guard !didCompleteDismissal else { return }
        didCompleteDismissal = true
        chrome.thumbnailStrip.setContentActive(false)
        playback.stop()
        for case let page as AttachmentPreviewPage in collectionView.visibleCells { page.reset() }
        didClose?()
        UIAccessibility.post(notification: .screenChanged, argument: sourceResolver?(currentIndex, false))
    }
    /// ListKit 负责注册、复用和稳定身份；页面只配置附件内容与回调。
    private func configure(_ page: AttachmentPreviewPage, item: AttachmentPreviewItem, index: Int) {
        page.semanticContentAttribute = view.semanticContentAttribute
        page.contentView.semanticContentAttribute = view.semanticContentAttribute
        page.configure(item, imageLoader: mediaImageLoader, isVisible: false, playbackCoordinator: playbackCoordinator)
        page.setLivePhotoMode(livePhotoModes[item.id] ?? .live)
        page.photoGeometryDidChange = { [weak self, weak page] in
            guard let self, let page, self.currentItem?.id == page.itemID else { return }
            self.chrome.updatePhotoRect(page.convert(page.fittedPhotoRect, to: self.chrome))
        }
        page.documentTopInset = chrome.documentTopInset
        page.toggleControls = { [weak self] in self?.toggleControls() }
        page.pageDidChange = { [weak self] number, count in
            guard let self, currentIndex == index else { return }
            chrome.updatePosition(String(format: Localization.text("imessage.preview.pages"), number, count))
        }
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? AttachmentPreviewPage)?.documentTopInset = chrome.documentTopInset
        (cell as? AttachmentPreviewPage)?.resumeImages()
        (cell as? AttachmentPreviewPage)?.setOriginalActive(indexPath.item == currentIndex && !isThumbnailScrubbing && !isHorizontalPaging && view.window != nil)
        if indexPath.item == currentIndex, !isThumbnailScrubbing { (cell as? AttachmentPreviewPage)?.bind(player: playback.player) }
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? AttachmentPreviewPage)?.bind(player: nil)
        (cell as? AttachmentPreviewPage)?.suspendImages()
    }
    /// 旋转前使用旧尺寸确定锚点；程序翻页保留目标，手势翻页保留最近可见项。
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        chrome.thumbnailStrip.endScrubbing()
        rotationPageIndex = pendingPageIndex ?? pagingLayout.index(nearestTo: collectionView.contentOffset)
        stopHorizontalScrolling()
        super.viewWillTransition(to: size, with: coordinator)
    }
    var isHorizontalPaging: Bool {
        pendingPageIndex != nil || pagingLayout.dragStartIndex != nil || collectionView.isDragging || collectionView.isDecelerating
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, !isPositioningPage else { return }
        chrome.thumbnailStrip.endScrubbing()
        pendingPageIndex = nil
        pagingStartIndex = currentIndex
        suspendOriginals()
        playback.pause()
        pagingLayout.beginDragging(at: collectionView.contentOffset)
        commitCurrentPage(pagingLayout.index(nearestTo: collectionView.contentOffset))
        synchronizeThumbnailPosition()
    }
    /// 主图的真实滚动进度同时驱动缩略图尺寸、间距及居中，取消手势也连续恢复。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, !isPositioningPage, !isThumbnailScrubbing else { return }
        synchronizeThumbnailPosition()
    }
    /// 隐藏时只记录进度，显示时立即恢复当前主图位置。
    private func synchronizeThumbnailPosition() {
        guard pagingLayout.metrics.stride > 0 else { return }
        chrome.thumbnailStrip.setPagingPosition(collectionView.contentOffset.x / pagingLayout.metrics.stride)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }; settlePage()
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, let target = pendingPageIndex,
              abs(scrollView.contentOffset.x - pagingLayout.offset(for: target).x) < 0.5 else { return }
        // 被新跳转替换的旧动画可能迟到结束；只有当前目标抵达时才提交。
        settlePage()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === collectionView, !decelerate else { return }; settlePage()
    }
    private func settlePage() {
        guard !isPositioningPage, collectionView.bounds.width > 0 else { return }
        let index = pendingPageIndex ?? pagingLayout.dragTargetIndex ?? pagingLayout.index(nearestTo: collectionView.contentOffset)
        finishPaging(at: index, autoplayVideo: index != (pagingStartIndex ?? currentIndex))
    }
    /// 取消旧动画及拖动，屏蔽取消过程中 UIKit 同步发出的结束回调。
    private func stopHorizontalScrolling() {
        isPositioningPage = true
        pagingStartIndex = nil
        pendingPageIndex = nil
        pagingLayout.endDragging()
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        if collectionView.isTracking || collectionView.isDragging {
            collectionView.panGestureRecognizer.isEnabled = false
            collectionView.panGestureRecognizer.isEnabled = true
        }
        isPositioningPage = false
    }
    private func commitCurrentPage(_ index: Int) {
        let index = AttachmentPreviewPolicy.index(index, count: items.count)
        guard index != currentIndex else { return }
        playback.stop()
        currentPage?.bind(player: nil)
        currentPage?.setOriginalActive(false)
        currentIndex = index
        updateCurrentItem()
    }
    /// 所有滚动结束路径共用精确停页与当前附件同步。
    /// autoplayVideo 仅由用户切换索引的完成路径开启，布局和关闭过程不自动播放。
    private func finishPaging(at index: Int, autoplayVideo: Bool = false) {
        isPositioningPage = true
        pagingStartIndex = nil
        pendingPageIndex = nil
        pagingLayout.endDragging()
        collectionView.setContentOffset(pagingLayout.offset(for: index), animated: false)
        commitCurrentPage(index)
        chrome.thumbnailStrip.select(index)
        collectionView.layoutIfNeeded()
        bindCurrentPlayer()
        isPositioningPage = false
        updateOriginalEligibility()
        if let page = currentPage { chrome.updatePhotoRect(page.convert(page.fittedPhotoRect, to: chrome)) }
        if autoplayVideo { autoplayCurrentVideo() }
    }
    /// 缩略图与菜单使用布局提供的坐标，连续跳转会替换旧目标。
    func select(_ index: Int, animated: Bool) {
        loadViewIfNeeded()
        collectionView.layoutIfNeeded()
        let index = AttachmentPreviewPolicy.index(index, count: items.count)
        stopHorizontalScrolling()
        let target = pagingLayout.offset(for: index)
        if animated, !UIAccessibility.isReduceMotionEnabled, view.window != nil, abs(target.x - collectionView.contentOffset.x) > 0.5 {
            playback.pause()
            pendingPageIndex = index
            suspendOriginals()
            collectionView.setContentOffset(target, animated: true)
        } else {
            finishPaging(at: index, autoplayVideo: index != currentIndex)
        }
    }
    /// 翻页和缩略图拖动期间只保留封面，不解码经过的原件。
    private func suspendOriginals() {
        for case let page as AttachmentPreviewPage in collectionView.visibleCells { page.setOriginalActive(false) }
    }

    /// 仅稳定当前页在预览器显示期间有资格加载原图。
    private func updateOriginalEligibility() {
        let stable = !isHorizontalPaging && !isThumbnailScrubbing && !didCompleteDismissal && view.window != nil
        for case let page as AttachmentPreviewPage in collectionView.visibleCells {
            page.setOriginalActive(stable && page.itemID == currentItem?.id)
        }
    }

    /// 播放模式只属于当前预览会话，不修改附件原件或保存结果。
    func setLivePhotoMode(_ mode: LivePhotoPlaybackMode) {
        guard let item = currentItem, item.isLivePhoto else { return }
        livePhotoModes[item.id] = mode
        currentPage?.setLivePhotoMode(mode)
        chrome.updateLivePhoto(isLivePhoto: true, mode: mode)
    }

    private func updateCurrentItem() {
        guard let item = currentItem else { return }
        chrome.updateItem(
            title: item.title.isEmpty ? Localization.text(item.kind == .video ? "imessage.media.video" : "imessage.media.image") : item.title,
            position: positionText(index: currentIndex), isPlayable: item.kind == .audio || item.kind == .video)
        chrome.updateLivePhoto(isLivePhoto: item.isLivePhoto, mode: livePhotoModes[item.id] ?? .live)
        updateMoreMenu()
        prepareCurrentPlayback()
        chrome.thumbnailStrip.select(currentIndex)
        refreshPlayback()
    }
    /// 只有稳定项目需要播放器；连续浏览的中间项目只展示封面。
    private func prepareCurrentPlayback() {
        guard !isThumbnailScrubbing, let item = currentItem,
              item.kind == .video || item.kind == .audio else { return }
        playback.prepare(url: item.url)
        bindCurrentPlayer()
    }
    /// 首次展开完成或用户翻到新视频并停稳后播放；布局刷新及手动暂停不触发此入口。
    /// 拖动中的中间项目、后台或关闭中的页面不得启动任务，已有播放或激活也不能被 toggle 暂停。
    private func autoplayCurrentVideo() {
        guard !isThumbnailScrubbing, !isHorizontalPaging, !didCompleteDismissal,
              !isBeingDismissed, view.window != nil, UIApplication.shared.applicationState == .active,
              currentItem?.kind == .video, !playback.isPlaying, playback.activationTask == nil else { return }
        prepareCurrentPlayback()
        playback.toggle()
    }
    /// 浏览期间不把旧播放器绑定到中间页面。
    private func bindCurrentPlayer() {
        guard !isThumbnailScrubbing else { return }
        currentPage?.bind(player: playback.player)
    }
    private func positionText(index: Int) -> String { String(format: Localization.text("imessage.preview.position"), index + 1, items.count) }
    /// 菜单边界跟随当前项目更新，RTL 下使用语义方向图标。
    private func updateMoreMenu() {
        var actions: [UIAction] = []
        if items.count > 1 {
            actions.append(UIAction(title: Localization.text("imessage.preview.previous"), image: UIImage(systemName: "chevron.backward"), attributes: currentIndex == 0 ? .disabled : []) { [weak self] _ in
                guard let self else { return }; select((pendingPageIndex ?? currentIndex) - 1, animated: true)
            })
            actions.append(UIAction(title: Localization.text("imessage.preview.next"), image: UIImage(systemName: "chevron.forward"), attributes: currentIndex == items.count - 1 ? .disabled : []) { [weak self] _ in
                guard let self else { return }; select((pendingPageIndex ?? currentIndex) + 1, animated: true)
            })
        }
        actions.append(UIAction(title: Localization.text("imessage.preview.hideControls"), image: UIImage(systemName: "rectangle"), attributes: UIAccessibility.isVoiceOverRunning ? .disabled : []) { [weak self] _ in self?.toggleControls() })
        chrome.updateMenu(UIMenu(children: actions))
    }
    private func refreshPlayback() {
        chrome.updatePlayback(time: playback.time, duration: playback.duration,
                              isPlaying: playback.isPlaying, isMuted: playback.isMuted, isSeeking: playback.isSeeking)
    }
    @objc func playTapped() {
        if playback.player == nil, let item = currentItem {
            playback.prepare(url: item.url)
            bindCurrentPlayer()
        }
        playback.toggle()
    }
    @objc func closeTapped() {
        currentPage?.stopLivePhotoPlayback()
        guard !transitionHandler.isInteracting, !isBeingDismissed else { return }
        let index = pagingLayout.index(nearestTo: collectionView.contentOffset)
        stopHorizontalScrolling()
        finishPaging(at: index)
        dismiss(animated: true)
    }
    override func accessibilityPerformEscape() -> Bool { closeTapped(); return true }
    /// 主图单击与菜单共用控制层的沉浸显隐状态。
    func toggleControls() { chrome.toggleControls() }
    /// 环境变更时更新菜单权限和视觉设置，控制层负责自身显隐。
    private func applyAccessibilitySettings() {
        updateMoreMenu()
        chrome.applyAccessibilitySettings()
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        return !isHorizontalPaging && velocity.y > abs(velocity.x) * 1.2 && currentPage?.permitsDismissal == true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let view = target {
            if view is UIControl || view is AttachmentThumbnailStripView || view === chrome { return false }
            target = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && otherGestureRecognizer is UIPanGestureRecognizer && currentPage?.permitsDismissal == true
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        switch gesture.state {
        case .began:
            currentPage?.stopLivePhotoPlayback()
            transitionHandler.begin()
        case .changed: transitionHandler.update(translation: translation)
        case .ended: transitionHandler.end(translation: translation, velocity: gesture.velocity(in: view))
        case .cancelled, .failed: transitionHandler.cancel()
        default: break
        }
    }
    isolated deinit { accessibilityObservers.forEach(NotificationCenter.default.removeObserver) }
}

#if DEBUG
@available(iOS 26.0, *)
#Preview("附件预览 · Liquid Glass") {
    AttachmentPreviewController(items: ConversationPreviewData.attachmentPreviewItems, initialIndex: 0, playbackCoordinator: PlaybackCoordinator())
}
#endif
