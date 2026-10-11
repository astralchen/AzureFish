import AzureFishAPI
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 按当前图片的位置决定横滑归属，避免等待已禁用的内层拖动手势。
private final class MomentsPagingCollectionView: UICollectionView {
    var canBeginPaging: ((CGPoint) -> Bool)?
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           canBeginPaging?(panGestureRecognizer.velocity(in: self)) == false { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// 黑底全屏图片预览，复用带 20 pt 页间距的自定义布局。
final class MomentsPhotoViewController: LocalizedQuickLayoutHostingController, UICollectionViewDelegate, UIGestureRecognizerDelegate {
    private let runtime: MomentsRuntime
    private let post: MomentsPost
    private let hadAccount: Bool
    private(set) var index: Int
    let pagingLayout: AttachmentPagingLayout
    let collection: UICollectionView
    private lazy var adapter = CollectionListAdapter<Int>(collectionView: collection)
    let loader: MomentsPhotoLoader
    let backdrop = UIView()
    let bar = UINavigationBar()
    private let barItem = UINavigationItem()
    private let position = UILabel()
    private let unavailable = UILabel()
    private var observation: UUID?
    private var lastSize = CGSize.zero
    private var previousMetrics = AttachmentPagingLayout.Metrics(size: .zero, count: 0)
    private var positioning = false
    /// 程序化翻页的目标；动画完成或窗口尺寸改变后用于提交稳定页位置。
    var pendingIndex: Int?
    var invalidated = false
    var closing = false
    var controlsHidden = false
    var draggingClose = false
    lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    var didClose: (() -> Void)?
    var currentPage: MomentsPhotoPage? { collection.cellForItem(at: IndexPath(item: index, section: 0)) as? MomentsPhotoPage }
    init(runtime: MomentsRuntime, post: MomentsPost, index: Int) {
        self.runtime = runtime; self.post = post; hadAccount = runtime.ready
        self.index = min(max(0, index), max(0, post.images.count - 1))
        let layout = AttachmentPagingLayout(); pagingLayout = layout
        collection = MomentsPagingCollectionView(frame: .zero, collectionViewLayout: layout)
        loader = MomentsPhotoLoader(assets: post.images, target: post.id, cache: runtime.photoCache,
            placeholder: { runtime.cachedThumbnail($0, target: post.id) }) { [runtime, post] asset in
            try await runtime.work { try await runtime.image(asset, target: post.id, original: true) }
        }
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen; modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        ZStack {
            backdrop.resizable()
            collection.resizable()
            unavailable.resizable(axis: .horizontal).padding(32)
            VStack(spacing: 0) { bar.resizable().frame(height: 44); Spacer() }.safeAreaPadding(.top)
        }
    }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { controlsHidden }
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad()
        view.backgroundColor = .clear; view.overrideUserInterfaceStyle = .dark
        view.accessibilityIdentifier = "moments.preview"; view.accessibilityViewIsModal = true
        backdrop.backgroundColor = .black; backdrop.isUserInteractionEnabled = false
        unavailable.textColor = .white; unavailable.numberOfLines = 0; unavailable.textAlignment = .center
        unavailable.font = .preferredFont(forTextStyle: .body); unavailable.adjustsFontForContentSizeCategory = true; unavailable.isHidden = true
        collection.backgroundColor = .clear; collection.contentInsetAdjustmentBehavior = .never
        collection.showsHorizontalScrollIndicator = false; collection.showsVerticalScrollIndicator = false
        collection.decelerationRate = .fast; collection.isPagingEnabled = false
        collection.panGestureRecognizer.maximumNumberOfTouches = 1
        (collection as? MomentsPagingCollectionView)?.canBeginPaging = { [weak self] velocity in
            guard let page = self?.currentPage else { return true }
            return !page.isZoomed || page.shouldYieldPan(velocity)
        }
        collection.alwaysBounceHorizontal = post.images.count > 1
        collection.semanticContentAttribute = .forceLeftToRight; collection.accessibilityIdentifier = "moments.photo.pager"
        let appearance = UINavigationBarAppearance(); appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance; bar.scrollEdgeAppearance = appearance; bar.compactAppearance = appearance
        bar.tintColor = .white; bar.setItems([barItem], animated: false)
        position.textColor = .white; position.font = .preferredFont(forTextStyle: .headline); position.adjustsFontForContentSizeCategory = true
        position.accessibilityIdentifier = "moments.photo.position"; barItem.titleView = position
        dismissPan.maximumNumberOfTouches = 1; dismissPan.delegate = self; view.addGestureRecognizer(dismissPan)
        collection.panGestureRecognizer.require(toFail: dismissPan)
        adapter.collectionDelegate = self; adapter.scrollDelegate = self
        adapter.apply(transaction: .disabled) {
            ListSection(0) {
                ListKit.ForEach(Array(post.images.enumerated()), id: \.element.id) { entry in
                    Row(entry.element.id, model: entry.offset, cell: MomentsPhotoPage.self) { [weak self] page, index, _ in self?.configure(page, at: index) }
                }
            }.selectionMode(.none)
        }
        loader.didChange = { [weak self] in self?.updatePages() }
        loader.updateWindow(around: index)
        observation = runtime.observe { [weak self] in
            guard let self else { return }
            if (hadAccount && !runtime.ready) || !runtime.visible(author: "").contains(where: { $0.id == post.id && $0.images == post.images }) { invalidateImages() }
        }
        reloadLocalizedContent()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: bar)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { loader.stop() }
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }
        collection.semanticContentAttribute = .forceLeftToRight
        bar.semanticContentAttribute = Localization.currentUIKitDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.closePreview() })
        close.accessibilityLabel = Localization.text("common.close"); close.accessibilityIdentifier = "moments.photo.close"
        barItem.leftBarButtonItem = close
        unavailable.text = Localization.text("moments.unavailable")
        updatePosition(); updatePages()
    }
    /// 窗口尺寸改变时结束旧拖动，按旧布局确定页位置，再用新布局重新定位。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collection.bounds.size
        guard !positioning, size.width > 0, size.height > 0, size != lastSize else { return }
        let selected = pendingIndex ?? (pagingLayout.dragStartIndex == nil ? index : previousMetrics.index(nearestTo: collection.contentOffset))
        resetDismissal(animated: false)
        positioning = true
        collection.setContentOffset(collection.contentOffset, animated: false)
        if collection.isTracking || collection.isDragging {
            collection.panGestureRecognizer.isEnabled = false; collection.panGestureRecognizer.isEnabled = true
        }
        pagingLayout.endDragging(); pendingIndex = nil; lastSize = size
        pagingLayout.invalidateLayout(); collection.layoutIfNeeded()
        previousMetrics = pagingLayout.metrics
        collection.setContentOffset(pagingLayout.offset(for: selected), animated: false)
        positioning = false; commit(selected)
    }
    private func configure(_ page: MomentsPhotoPage, at index: Int) {
        guard post.images.indices.contains(index), !invalidated else { page.clear(); return }
        page.configure(assetID: post.images[index].id, index: index, state: loader.states[index])
        page.toggleControls = { [weak self] in self?.toggleControls() }
        page.zoomChanged = { [weak self] in self?.updateGestures() }
        page.retryImage = { [weak self] in self?.loader.retry(index) }
        page.changePage = { [weak self] step in self?.select(offset: step) ?? false }
        page.canTurnPage = { [weak self] step in
            guard let self else { return false }
            return !invalidated && !closing && !draggingClose && post.images.indices.contains(index + step)
        }
        page.close = { [weak self] in self?.closePreview() }
    }
    private func updatePages() {
        guard !invalidated else { return }
        for case let page as MomentsPhotoPage in collection.visibleCells {
            if let path = collection.indexPath(for: page) { configure(page, at: path.item) }
        }
        updateGestures()
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let page = cell as? MomentsPhotoPage { configure(page, at: indexPath.item) }
    }
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) { (cell as? MomentsPhotoPage)?.clear() }
    private func updatePosition() {
        position.text = Localization.text("moments.photoPosition", Int64(index + 1), Int64(post.images.count)); position.sizeToFit()
    }
    /// 缩放手势期间禁用外层分页；放大但未缩放时允许图片边缘把横滑交给分页。
    func updateGestures() {
        let page = currentPage
        let zooming = page?.zoomInteraction == true || page?.isZoomed == true
        collection.isScrollEnabled = !invalidated && !closing && !draggingClose && page?.zoomInteraction != true && post.images.count > 1
        dismissPan.isEnabled = !invalidated && !closing && !zooming
    }
    private func commit(_ selected: Int) {
        index = min(max(0, selected), max(0, post.images.count - 1)); updatePosition()
        if !invalidated { loader.updateWindow(around: index); updatePages() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === collection, !positioning else { return }
        pendingIndex = nil; pagingLayout.beginDragging(at: collection.contentOffset)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collection, !positioning, !invalidated else { return }
        loader.updateWindow(around: pagingLayout.index(nearestTo: collection.contentOffset))
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard let pendingIndex, abs(collection.contentOffset.x - pagingLayout.offset(for: pendingIndex).x) < 0.5 else { return }
        settle()
    }
    /// 将滚动位置吸附到目标页，提交当前索引并播报无障碍翻页结果。
    private func settle() {
        guard !positioning else { return }
        let selected = pendingIndex ?? pagingLayout.dragTargetIndex ?? pagingLayout.index(nearestTo: collection.contentOffset)
        positioning = true; pendingIndex = nil; pagingLayout.endDragging()
        collection.setContentOffset(pagingLayout.offset(for: selected), animated: false)
        positioning = false; commit(selected)
        UIAccessibility.post(notification: .pageScrolled, argument: position.text)
    }
    /// 相对当前位置请求翻页；越界或交互受限时返回 false，有动画时在动画结束后提交索引。
    @discardableResult func select(offset: Int) -> Bool {
        guard !invalidated, !closing, !draggingClose, currentPage?.zoomInteraction != true else { return false }
        let start = pagingLayout.index(nearestTo: collection.contentOffset), target = start + offset
        guard post.images.indices.contains(target) else { return false }
        pendingIndex = target; pagingLayout.endDragging()
        if UIAccessibility.isReduceMotionEnabled || view.window == nil { collection.setContentOffset(pagingLayout.offset(for: target), animated: false); settle() }
        else { collection.setContentOffset(pagingLayout.offset(for: target), animated: true) }
        return true
    }
    /// 立即停止加载并清除该动态预览缓存和可见图片，保留关闭入口与不可用提示。
    func invalidateImages() {
        guard !invalidated else { return }; invalidated = true; loader.stop(); runtime.photoCache.remove(target: post.id)
        for case let page as MomentsPhotoPage in collection.visibleCells { page.clear() }
        collection.isHidden = true; unavailable.isHidden = false
        resetDismissal(animated: false); controlsHidden = false; bar.alpha = 1; bar.accessibilityElementsHidden = false
        setNeedsStatusBarAppearanceUpdate(); updateGestures()
    }
    func closePreview() {
        guard !closing else { return }; closing = true; loader.stop(); updateGestures()
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled, completion: didClose)
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .left || direction == .right else { return false }
        return select(offset: direction == .left ? 1 : -1)
    }
    override func accessibilityPerformEscape() -> Bool { closePreview(); return true }
    isolated deinit { loader.stop(); if let observation { runtime.remove(observation) } }
}


#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈图片") { MomentsPhotoViewController(runtime: MomentsPreviewData.runtime(), post: MomentsPreviewData.posts[0], index: 0) }
#endif
