import QuickLayout
import QuickLayoutKit
import UIKit

/// 在放大图片边缘把向外的横向拖动交给外层分页。
private final class MomentsImageScrollView: UIScrollView {
    var shouldBeginPan: ((CGPoint) -> Bool)?
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           shouldBeginPan?(panGestureRecognizer.velocity(in: self)) == false { return false }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

/// 可复用图片页；常规内容使用 QuickLayout，缩放图像使用 UIScrollView 坐标布局。
final class MomentsPhotoPage: QuickLayoutCollectionViewCell, UIScrollViewDelegate {
    let scroll: UIScrollView = MomentsImageScrollView()
    let imageView = UIImageView()
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private var previousSize = CGSize.zero
    private var imageNeedsLayout = false
    private var layingOutImage = false
    private(set) var assetID: String?
    private(set) var zoomInteraction = false
    var toggleControls: (() -> Void)?
    var zoomChanged: (() -> Void)?
    var retryImage: (() -> Void)?
    var changePage: ((Int) -> Bool)?
    /// 查询相邻页是否可用；参数 -1 表示上一页、1 表示下一页，nil 时不让出图片拖动。
    var canTurnPage: ((Int) -> Bool)?
    var close: (() -> Void)?
    var isZoomed: Bool { scroll.zoomScale > 1.01 }
    override func synchronizeLayoutDirectionFromCollectionViewIfNeeded() -> Bool { false }
    override var body: Layout {
        ZStack {
            scroll.resizable()
            VStack(spacing: 16) {
                status.resizable(axis: .horizontal)
                retry.frame(minWidth: 44, minHeight: 44)
            }.padding(24)
        }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize; quickLayoutVerticalFlexibility = .fixedSize
        backgroundColor = .clear; contentView.backgroundColor = .clear
        scroll.delegate = self; scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.panGestureRecognizer.isEnabled = false
        (scroll as? MomentsImageScrollView)?.shouldBeginPan = { [weak self] velocity in
            !(self?.shouldYieldPan(velocity) ?? false)
        }
        scroll.addSubview(imageView); imageView.contentMode = .scaleAspectFit; imageView.isAccessibilityElement = true
        status.textColor = .white; status.numberOfLines = 0; status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body); status.adjustsFontForContentSizeCategory = true
        retry.tintColor = .white; retry.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retry.titleLabel?.adjustsFontForContentSizeCategory = true
        retry.addAction(UIAction { [weak self] _ in self?.retryImage?() }, for: .touchUpInside)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:))); doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(singleTapped)); tap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(tap); scroll.addGestureRecognizer(doubleTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 仅在放大图片已到水平边缘且存在相邻页时让出向外拖动；velocity 使用滚动视图坐标。
    func shouldYieldPan(_ velocity: CGPoint) -> Bool {
        guard isZoomed, !zoomInteraction, abs(velocity.x) > abs(velocity.y) else { return false }
        let step = velocity.x < 0 ? 1 : -1
        guard canTurnPage?(step) == true else { return false }
        // 内容 inset 参与边缘计算，1 点容差吸收缩放和居中后的浮点误差。
        let minimum = -scroll.adjustedContentInset.left
        let maximum = max(minimum, scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        return step > 0 ? scroll.contentOffset.x >= maximum - 1 : scroll.contentOffset.x <= minimum + 1
    }
    /// 应用图片加载状态；同一资源保留缩放和位置，资源身份改变时先清空旧页。
    func configure(assetID: String, index: Int, state: MomentsPhotoLoader.State?) {
        if self.assetID != assetID { clear(); self.assetID = assetID }
        accessibilityIdentifier = "moments.preview.page.\(index)"
        imageView.accessibilityIdentifier = "moments.preview.image.\(index)"
        imageView.accessibilityLabel = Localization.text("moments.photoNumber", Int64(index + 1))
        imageView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: Localization.text("moments.previous")) { [weak self] _ in self?.changePage?(-1) ?? false },
            UIAccessibilityCustomAction(name: Localization.text("moments.next")) { [weak self] _ in self?.changePage?(1) ?? false },
            UIAccessibilityCustomAction(name: Localization.text("common.close")) { [weak self] _ in self?.close?(); return true }
        ]
        retry.setTitle(Localization.text("moments.retry"), for: .normal)
        retry.accessibilityIdentifier = "moments.preview.retry.\(index)"
        switch state {
        case .image(let image):
            status.isHidden = true; retry.isHidden = true
            display(image)
        case .preview(let image, let failure):
            display(image)
            status.isHidden = failure == nil; status.text = failure.map { Localization.text($0) }
            retry.isHidden = failure == nil
        case .failed(let key):
            imageView.image = nil; status.isHidden = false; status.text = Localization.text(key); retry.isHidden = false
        case .loading, nil:
            imageView.image = nil; status.isHidden = false; status.text = Localization.text("moments.loading"); retry.isHidden = true
        }
        setNeedsQuickLayout()
    }
    private func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image; imageNeedsLayout = true; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layingOutImage, (imageNeedsLayout || scroll.bounds.size != previousSize), scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        layoutImage()
    }
    /// 重新适配图片尺寸，并按归一化图像坐标恢复可见中心和原缩放倍数。
    private func layoutImage() {
        layingOutImage = true; defer { layingOutImage = false }
        let zoom = scroll.zoomScale
        let old = imageView.bounds.size
        let normalized = CGPoint(x: (scroll.contentOffset.x + previousSize.width / 2) / max(1, old.width * zoom),
                                 y: (scroll.contentOffset.y + previousSize.height / 2) / max(1, old.height * zoom))
        let initialized = previousSize != .zero
        scroll.zoomScale = 1
        let source = imageView.image?.size ?? scroll.bounds.size
        let scale = min(scroll.bounds.width / max(1, source.width), scroll.bounds.height / max(1, source.height))
        imageView.frame = CGRect(origin: .zero, size: CGSize(width: source.width * scale, height: source.height * scale))
        scroll.contentSize = imageView.bounds.size; scroll.zoomScale = zoom
        previousSize = scroll.bounds.size; imageNeedsLayout = false; centerImage()
        if initialized {
            scroll.contentOffset = CGPoint(x: clamped(normalized.x * scroll.contentSize.width - scroll.bounds.width / 2, axis: .horizontal),
                                           y: clamped(normalized.y * scroll.contentSize.height - scroll.bounds.height / 2, axis: .vertical))
        } else { scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top) }
    }
    private func clamped(_ value: CGFloat, axis: NSLayoutConstraint.Axis) -> CGFloat {
        let inset = axis == .horizontal ? scroll.contentInset.left : scroll.contentInset.top
        let content = axis == .horizontal ? scroll.contentSize.width : scroll.contentSize.height
        let viewport = axis == .horizontal ? scroll.bounds.width : scroll.bounds.height
        return max(-inset, min(value, max(-inset, content - viewport + inset)))
    }
    private func centerImage() {
        let x = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        let y = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { zoomInteraction = true; zoomChanged?() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage(); scroll.panGestureRecognizer.isEnabled = isZoomed
        imageView.accessibilityValue = NumberFormatter.localizedString(from: NSNumber(value: Double(scroll.zoomScale)), number: .percent)
        if !layingOutImage { zoomChanged?() }
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { zoomInteraction = false; zoomChanged?() }
    @objc private func singleTapped() { toggleControls?() }
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        guard imageView.image != nil else { toggleControls?(); return }
        if isZoomed { scroll.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled); return }
        let point = gesture.location(in: imageView)
        let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard direction == .left || direction == .right else { return false }
        return changePage?(direction == .left ? 1 : -1) ?? false
    }
    override func accessibilityPerformEscape() -> Bool { close?(); return true }
    /// 清除图像和几何状态；回调由 prepareForReuse 统一解除。
    func clear() {
        assetID = nil; imageView.image = nil; zoomInteraction = false; scroll.zoomScale = 1; scroll.contentInset = .zero
        scroll.contentOffset = .zero; scroll.panGestureRecognizer.isEnabled = false; previousSize = .zero; imageNeedsLayout = false
    }
    override func prepareForReuse() {
        super.prepareForReuse(); clear()
        toggleControls = nil; zoomChanged = nil; retryImage = nil; changePage = nil; canTurnPage = nil; close = nil
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈缩放图片页") {
    let page = MomentsPhotoPage(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    page.backgroundColor = .black
    page.configure(assetID: "fixture", index: 0, state: UIImage(data: MomentsPreviewData.image(1)).map(MomentsPhotoLoader.State.image))
    return page
}
#endif
