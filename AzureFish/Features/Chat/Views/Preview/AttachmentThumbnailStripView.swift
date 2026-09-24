import UIKit
import QuickLayout
import QuickLayoutKit

/// 可复用缩略图；图片与请求均绑定到本次配置身份。
final class AttachmentThumbnailStripCell: UICollectionViewCell {
    /// 固定高度、随 Cell 宽度裁剪的图片。
    let imageView = UIImageView()
    /// 当前绑定的附件索引。
    private(set) var itemIndex: Int?
    /// 当前加载操作的有效期，拒绝旧请求回写。
    private let loadingScope = OperationScope()
    /// Cell 不拥有加载器，其生命周期由缩略图条管理。
    private weak var loader: MediaImageLoader?
    /// 当前消费者的取消句柄。
    private var request: MediaImageLoader.Request?
    /// 当前显示配置，隐藏后重新显示时可重启未完成请求。
    private var item: AttachmentPreviewItem?
    /// 当前屏幕的像素需求。
    private var pixels = 90
    /// 是否已获得图片或失败占位，避免重复读取损坏文件。
    private var didFinishLoading = false
    /// VoiceOver 激活动作与普通点击共用宿主切页入口。
    var activate: (() -> Void)?

    /// 创建透明 Cell，图片外保留垂直点击空间。
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 2
        imageView.tintColor = .white
        contentView.addSubview(imageView)
        isAccessibilityElement = true
    }
    /// 缩略图仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 图像保持 30 pt 高，Cell 本身提供 44 pt 的命中区域。
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = CGRect(x: 0, y: (bounds.height - 30) / 2, width: bounds.width, height: 30)
    }
    /// 配置身份、占位图及辅助功能，加载仅在可见阶段启动。
    func configure(item: AttachmentPreviewItem, index: Int, count: Int, loader: MediaImageLoader, scale: CGFloat) {
        cancelLoading()
        self.item = item
        itemIndex = index
        self.loader = loader
        pixels = max(1, Int(ceil(30 * scale)))
        didFinishLoading = false
        imageView.image = UIImage(systemName: item.kind == .video ? "video.fill" : "doc.fill")
        accessibilityLabel = String(format: Localization.text("imessage.preview.position"), index + 1, count)
        accessibilityIdentifier = "imessage.preview.thumbnail.\(index)"
    }
    /// 可见或重新显示时恢复加载；同一配置只允许一个消费者。
    func loadIfNeeded() {
        guard request == nil, !didFinishLoading, let url = item?.thumbnailURL, let loader else { return }
        let operation = loadingScope.begin()
        request = loader.load(url: url, pixels: pixels) { [weak self] image in
            guard let self, operation.isCurrent else { return }
            request = nil
            didFinishLoading = true
            if let image { imageView.image = image }
        }
    }
    /// 离屏或隐藏时使旧回写失效并释放像素，重新显示时从共享缓存恢复。
    func cancelLoading() {
        loadingScope.invalidate()
        loader?.cancel(request)
        request = nil
        didFinishLoading = false
        imageView.image = nil
    }
    /// 正式选中状态只改变辅助功能语义，展开由布局连续控制。
    func updateSelection(_ selected: Bool) {
        isSelected = selected
        accessibilityTraits = selected ? [.button, .selected] : .button
    }
    /// 清除上一次复用的身份、图片及回调。
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoading()
        item = nil
        itemIndex = nil
        imageView.image = nil
        activate = nil
        updateSelection(false)
    }
    /// 辅助功能点击同样只请求切页。
    override func accessibilityActivate() -> Bool { activate?(); return activate != nil }
}

/// 透明悬浮的照片胶片条：复用图片、连续展开并同步主图浏览进度。
@available(iOS 26.0, *)
final class AttachmentThumbnailStripView: QuickLayoutView, UICollectionViewDataSource, UICollectionViewDelegate {
    /// 在控制层中占用的高度，图片本身仅高 30 pt。
    static let preferredHeight: CGFloat = 64
    /// 点击请求，正式选中项由宿主提交。
    var didSelectItem: ((Int) -> Void)?
    /// 用户开始拖动缩略图，宿主应取消旧翻页目标。
    var didBeginScrubbing: (() -> Void)?
    /// 拖动或减速期间中央最近索引变化。
    var didScrubToItem: ((Int) -> Void)?
    /// 最终吸附完成后提交当前项。
    var didEndScrubbing: ((Int) -> Void)?
    /// 当前正式选中项，空数据没有选中项。
    private(set) var selectedIndex: Int?
    /// 手势及其减速期间由缩略图独占进度驱动。
    private(set) var isScrubbing = false
    /// 隐藏期间只存储进度，不发起图片请求或更新显示几何。
    private(set) var isContentActive = true
    /// 最新连续浏览位置，包括沉浸隐藏期间的更新。
    private(set) var pagingPosition: CGFloat = 0
    /// 本次预览的不可变数据。
    private let items: [AttachmentPreviewItem]
    /// 自定义布局公开给同模块验证几何。
    let stripLayout = AttachmentThumbnailStripLayout()
    /// 透明列表；只在 44 pt 的交互带内命中。
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: stripLayout)
    /// 有界后台图片加载器。
    let imageLoader: MediaImageLoader
    /// 固定在视口两端的透明度遮罩。
    private let fade = CAGradientLayer()
    /// 防止程序定位被解释为用户滚动。
    private var isPositioning = false
    /// 最近发送给宿主的拖动索引。
    private var lastScrubIndex: Int?
    /// 尺寸变化时重新定位。
    private var lastSize = CGSize.zero
    /// 独立 select 动画的逐帧驱动。
    private var displayLink: CADisplayLink?
    /// 动画的起点、终点和开始时间。
    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    /// CADisplayLink 使用弱代理，避免引用环。
    @MainActor
    private final class DisplayTarget: NSObject {
        /// 不拥有缩略图视图。
        weak var owner: AttachmentThumbnailStripView?
        /// 将时钟转发到仍存活的视图。
        @objc func tick(_ link: CADisplayLink) { owner?.animateFrame(link) }
    }
    /// 被时钟保留的轻量转发器。
    private let displayTarget = DisplayTarget()

    /// 列表内容透明，背景材质由实际操作控件自行管理。
    override var body: Layout { collectionView.resizable().frame(height: Self.preferredHeight) }

    /// 创建按需加载的列表，不提前创建任何缩略图。
    init(items: [AttachmentPreviewItem], selectedIndex: Int = 0, imageLoader: MediaImageLoader? = nil) {
        self.imageLoader = imageLoader ?? MediaImageLoader()
        self.items = items
        super.init(frame: .zero)
        semanticContentAttribute = .forceLeftToRight
        collectionView.semanticContentAttribute = .forceLeftToRight
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.alwaysBounceHorizontal = false
        collectionView.isPrefetchingEnabled = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AttachmentThumbnailStripCell.self, forCellWithReuseIdentifier: "thumbnail")
        accessibilityIdentifier = "imessage.preview.thumbnails"
        fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        layer.mask = fade
        displayTarget.owner = self
        select(selectedIndex)
    }
    /// 缩略图条仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 空白上下边缘透传，渐隐不影响中间交互带。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isContentActive && bounds.contains(point) && abs(point.y - bounds.midY) <= 22
    }
    /// 越界索引收敛，程序提交不触发点击回调；手势期间不改写偏移。
    func select(_ index: Int, animated: Bool = false) {
        selectedIndex = items.isEmpty ? nil : AttachmentPreviewPolicy.index(index, count: items.count)
        updateVisibleSelection()
        guard !isScrubbing else { return }
        cancelAnimation()
        let target = CGFloat(selectedIndex ?? 0)
        if animated, isContentActive, window != nil, !UIAccessibility.isReduceMotionEnabled, target != pagingPosition {
            animation = (pagingPosition, target, CACurrentMediaTime())
            let link = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.tick(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        } else { applyPosition(target) }
    }
    /// 主图连续进度只驱动显示，不提前提交正式选中项。
    func setPagingPosition(_ position: CGFloat) {
        guard !isScrubbing else { return }
        cancelAnimation()
        applyPosition(position)
    }
    /// 沉浸隐藏时停止工作；显示前同步最新锚点并恢复当前可见请求。
    func setContentActive(_ active: Bool) {
        guard active != isContentActive else { return }
        isContentActive = active
        accessibilityElementsHidden = !active
        isUserInteractionEnabled = active
        if !active {
            cancelAnimation()
            endScrubbing()
            for case let cell as AttachmentThumbnailStripCell in collectionView.visibleCells { cell.cancelLoading() }
        } else {
            updateVisibleSelection()
            applyPosition(pagingPosition)
            collectionView.layoutIfNeeded()
            for case let cell as AttachmentThumbnailStripCell in collectionView.visibleCells { cell.loadIfNeeded() }
        }
    }
    /// 主图接管手势时停止缩略图减速并提交最近项。
    func endScrubbing() {
        guard isScrubbing else { return }
        isPositioning = true
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        if collectionView.isTracking || collectionView.isDragging {
            collectionView.panGestureRecognizer.isEnabled = false
            collectionView.panGestureRecognizer.isEnabled = true
        }
        isPositioning = false
        finishScrubbing()
    }
    /// 逐帧插值独立程序选择，尺寸与偏移始终共享同一进度。
    private func animateFrame(_ link: CADisplayLink) {
        guard let animation else { return }
        let fraction = min(1, max(0, (link.timestamp - animation.start) / 0.22))
        let eased = fraction * fraction * (3 - 2 * fraction)
        applyPosition(animation.from + (animation.to - animation.from) * eased)
        if fraction >= 1 { cancelAnimation() }
    }
    /// 新操作从当前进度接续，不接受旧时钟的完成结果。
    private func cancelAnimation() { displayLink?.invalidate(); displayLink = nil; animation = nil }
    /// 更新连续位置；只有主动定位会写 contentOffset。
    private func applyPosition(_ position: CGFloat, moveOffset: Bool = true) {
        pagingPosition = position.isFinite ? min(max(0, position), CGFloat(max(0, items.count - 1))) : 0
        guard isContentActive else { return }
        isPositioning = true
        stripLayout.position = pagingPosition
        if moveOffset, collectionView.bounds.width > 0 {
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(CGPoint(x: pagingPosition * AttachmentThumbnailStripLayout.Metrics.stride, y: 0), animated: false)
        }
        isPositioning = false
    }
    /// 只更新已存在的 Cell，不遍历全部附件。
    private func updateVisibleSelection() {
        guard isContentActive else { return }
        for path in collectionView.indexPathsForSelectedItems ?? [] where path.item != selectedIndex {
            collectionView.deselectItem(at: path, animated: false)
        }
        if let selectedIndex {
            collectionView.selectItem(at: IndexPath(item: selectedIndex, section: 0), animated: false, scrollPosition: [])
        }
        for case let cell as AttachmentThumbnailStripCell in collectionView.visibleCells { cell.updateSelection(cell.itemIndex == selectedIndex) }
    }
    /// 布局完成后恢复尺寸变化前的位置，遮罩不参与隐式动画。
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        let edge = min(0.5, 12 / max(1, bounds.width))
        fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        CATransaction.commit()
        if collectionView.bounds.size != lastSize {
            lastSize = collectionView.bounds.size
            applyPosition(pagingPosition)
        }
    }
    /// 单 section 提供全部索引，Cell 由列表按需请求。
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    /// 配置可复用 Cell，不在此提前启动不可见加载。
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "thumbnail", for: indexPath) as! AttachmentThumbnailStripCell
        cell.configure(item: items[indexPath.item], index: indexPath.item, count: items.count, loader: imageLoader, scale: traitCollection.displayScale)
        cell.updateSelection(indexPath.item == selectedIndex)
        cell.activate = { [weak self] in self?.requestSelection(indexPath.item) }
        return cell
    }
    /// 实际进入可见范围才读取图片。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if isContentActive { (cell as? AttachmentThumbnailStripCell)?.loadIfNeeded() }
    }
    /// 离屏立即撤销该 Cell 的消费者。
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? AttachmentThumbnailStripCell)?.cancelLoading()
    }
    /// 阻止 UICollectionView 提前改变正式选中项，由宿主翻页结果决定。
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        requestSelection(indexPath.item)
        return false
    }
    /// 点击或辅助功能激活共用入口，先结束残留的减速。
    private func requestSelection(_ index: Int) { endScrubbing(); didSelectItem?(index) }
    /// 缩略图开始独占滚动进度。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelAnimation()
        isScrubbing = true
        lastScrubIndex = selectedIndex
        didBeginScrubbing?()
    }
    /// 以固定步长反算进度，绝不使用展开后的最近 frame 反算。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isScrubbing, !isPositioning, isContentActive else { return }
        applyPosition(stripLayout.metrics.position(at: scrollView.contentOffset.x), moveOffset: false)
        let index = Int(pagingPosition.rounded())
        if lastScrubIndex != index, !items.isEmpty {
            lastScrubIndex = index
            selectedIndex = index
            updateVisibleSelection()
            didScrubToItem?(index)
        }
    }
    /// 无惯性时也必须精确吸附到整数项。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { finishScrubbing() } }
    /// 惯性结束后统一提交最终项。
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrubbing() }
    /// 清除手势所有权后通知宿主，允许宿主安全回传最终位置。
    private func finishScrubbing() {
        guard isScrubbing, !isPositioning else { return }
        isScrubbing = false
        guard !items.isEmpty else { return }
        let index = Int(pagingPosition.rounded())
        select(index)
        didEndScrubbing?(index)
        lastScrubIndex = nil
    }
    /// 析构时停止时钟，加载器自行取消后台工作。
    isolated deinit { displayLink?.invalidate() }
}

#if DEBUG
@available(iOS 26.0, *)
#Preview("附件缩略图导航") {
    let strip = AttachmentThumbnailStripView(items: ConversationPreviewData.attachmentPreviewItems)
    strip.didSelectItem = { [weak strip] index in strip?.select(index, animated: true) }
    return QuickLayoutView { strip.resizable().frame(height: AttachmentThumbnailStripView.preferredHeight).padding(16) }
}
#endif
