import UIKit

/// 附件专用全屏分页布局：页面间保留 20 pt，吸附位置不依赖系统整屏分页。
final class AttachmentPagingLayout: UICollectionViewLayout {
    /// 可独立验证的页面几何及单次手势吸附规则。
    struct Metrics: Equatable {
        let size: CGSize
        let count: Int
        static let spacing: CGFloat = 20
        var stride: CGFloat { size.width + Self.spacing }
        var contentSize: CGSize {
            guard count > 0, size.width > 0, size.height > 0 else { return .zero }
            return CGSize(width: CGFloat(count) * size.width + CGFloat(count - 1) * Self.spacing, height: size.height)
        }
        func clamped(_ index: Int) -> Int { min(max(0, index), max(0, count - 1)) }
        func offset(for index: Int) -> CGPoint { CGPoint(x: CGFloat(clamped(index)) * stride, y: 0) }
        func index(nearestTo offset: CGPoint) -> Int {
            guard size.width > 0, offset.x.isFinite else { return 0 }
            return clamped(Int((offset.x / stride).rounded()))
        }
        func frame(for index: Int) -> CGRect { CGRect(origin: offset(for: index), size: size) }
        /// 快滑要求至少 8 pt 同向位移；反向甩回起始页，慢拖以半页为界。
        func targetIndex(from start: Int, offset: CGPoint, velocity: CGFloat) -> Int {
            let start = clamped(start)
            let displacement = offset.x - self.offset(for: start).x
            let candidate: Int
            if abs(velocity) >= 0.35 {
                candidate = abs(displacement) >= 8 && displacement * velocity > 0
                    ? start + (velocity > 0 ? 1 : -1) : start
            } else {
                candidate = index(nearestTo: offset)
            }
            return clamped(min(start + 1, max(start - 1, candidate)))
        }
    }

    /// 保留上一份有效几何，供旋转时按旧步长识别当前可见页。
    private(set) var metrics = Metrics(size: .zero, count: 0)
    private var attributes: [UICollectionViewLayoutAttributes] = []
    private(set) var dragStartIndex: Int?
    private(set) var dragTargetIndex: Int?

    /// 普通滚动复用属性；尺寸或项目数变化才重建最多 20 页的几何。
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let next = Metrics(size: collectionView.bounds.size, count: collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0)
        guard next != metrics else { return }
        metrics = next
        attributes = (0..<next.count).map { index in
            let attribute = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = next.frame(for: index)
            return attribute
        }
    }
    override var collectionViewContentSize: CGSize { metrics.contentSize }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }.map { $0.copy() as! UICollectionViewLayoutAttributes }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item].copy() as? UICollectionViewLayoutAttributes
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != metrics.size }

    /// 固定物理分页顺序，应用内 RTL 只影响每页内容及控制层。
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { false }

    /// 记录手势起始页，打断程序动画时同样从实际可见页开始。
    func beginDragging(at offset: CGPoint) {
        dragStartIndex = metrics.index(nearestTo: offset)
        dragTargetIndex = nil
    }
    func endDragging() { dragStartIndex = nil; dragTargetIndex = nil }
    func offset(for index: Int) -> CGPoint { metrics.offset(for: index) }
    func index(nearestTo offset: CGPoint) -> Int { metrics.index(nearestTo: offset) }

    /// 忽略系统按惯性预测的跨页距离，单次拖动最多停在相邻页。
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        let offset = collectionView?.contentOffset ?? proposedContentOffset
        let start = dragStartIndex ?? metrics.index(nearestTo: offset)
        let target = metrics.targetIndex(from: start, offset: offset, velocity: velocity.x)
        dragTargetIndex = target
        return metrics.offset(for: target)
    }
}

#if DEBUG
@available(iOS 26.0, *)
#Preview("附件分页 · 20 pt 间隔") {
    AttachmentPreviewController(items: ConversationPreviewData.attachmentPreviewItems, initialIndex: 0, playbackCoordinator: .init())
}
#endif
