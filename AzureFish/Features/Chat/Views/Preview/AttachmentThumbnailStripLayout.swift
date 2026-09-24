import UIKit

/// 照片胶片条布局：固定逻辑步长，展开宽度和留白仅影响显示几何。
final class AttachmentThumbnailStripLayout: UICollectionViewLayout {
    /// 无视图依赖的连续几何；每次计算最多涉及两个展开项。
    struct Metrics {
        /// 当前视口尺寸。
        let size: CGSize
        /// 附件数量。
        let count: Int
        /// 来自主图或缩略图手势的连续索引。
        let position: CGFloat
        /// 普通项宽度与间距之和，保持滚动坐标稳定。
        static let stride: CGFloat = 23
        /// 已收敛到有效数据范围的进度。
        var progress: CGFloat { position.isFinite ? min(max(0, position), CGFloat(max(0, count - 1))) : 0 }
        /// 左侧过渡项。
        private var lower: Int { Int(progress.rounded(.down)) }
        /// 两项之间的过渡比例。
        private var fraction: CGFloat { progress - CGFloat(lower) }
        /// 逻辑内容宽度与选中几何无关，首尾均留出居中空间。
        var contentSize: CGSize { count > 0 ? CGSize(width: size.width + CGFloat(count - 1) * Self.stride, height: size.height) : .zero }
        /// 与进度一一对应的滚动位置。
        var offset: CGPoint { CGPoint(x: progress * Self.stride, y: 0) }
        /// 指定项目的展开权重。
        func weight(_ index: Int) -> CGFloat { max(0, 1 - abs(CGFloat(index) - progress)) }
        /// 指定项目之前的展开权重总和，不遍历数组。
        private func prefix(_ index: Int) -> CGFloat {
            (index > lower ? 1 - fraction : 0) + (index > lower + 1 ? fraction : 0)
        }
        /// 未平移的图片横坐标；宽度和相邻边距增量均计入真实 frame。
        private func rawX(_ index: Int) -> CGFloat {
            CGFloat(index) * Self.stride + 30 * prefix(index) - 10 * weight(0) + 10 * weight(index)
        }
        /// 两个过渡项目中心的插值，用于连续交接居中锚点。
        private var anchor: CGFloat {
            let first = rawX(lower) + (20 + 10 * weight(lower)) / 2
            guard lower + 1 < count else { return first }
            let second = rawX(lower + 1) + (20 + 10 * weight(lower + 1)) / 2
            return first + (second - first) * fraction
        }
        /// 将显示几何平移到稳定逻辑滚动轴。
        private var translation: CGFloat { size.width / 2 + offset.x - anchor }
        /// Cell 提供 44 pt 高的命中区域，内层图片高 30 pt。
        func frame(_ index: Int) -> CGRect {
            CGRect(x: rawX(index) + translation, y: (size.height - 44) / 2,
                   width: 20 + 10 * weight(index), height: 44)
        }
        /// 保守候选范围只比可见区域多常数个项目，不随总量增长。
        func candidates(in rect: CGRect) -> Range<Int> {
            guard count > 0, !rect.isNull, rect.minX.isFinite, rect.maxX.isFinite else { return 0..<0 }
            let first = max(0, min(count, Int(floor((rect.minX - translation - 60) / Self.stride))))
            let end = max(first, min(count, Int(ceil((rect.maxX - translation + 20) / Self.stride)) + 1))
            return first..<end
        }
        /// 将实际逻辑偏移转换为合法连续索引。
        func position(at offset: CGFloat) -> CGFloat {
            guard offset.isFinite else { return 0 }
            return min(max(0, offset / Self.stride), CGFloat(max(0, count - 1)))
        }
    }

    /// 当前显示进度，改变时仅使可见布局失效。
    var position: CGFloat = 0 {
        didSet { if position != oldValue { invalidateLayout() } }
    }
    /// 根据实时视口和数据源生成轻量几何。
    var metrics: Metrics {
        Metrics(size: collectionView?.bounds.size ?? .zero,
                count: (collectionView?.numberOfSections ?? 0) > 0 ? collectionView!.numberOfItems(inSection: 0) : 0,
                position: position)
    }
    /// 首尾居中所需的固定逻辑内容范围。
    override var collectionViewContentSize: CGSize { metrics.contentSize }
    /// 只为候选范围中真正相交的 Cell 创建属性。
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let geometry = metrics
        return geometry.candidates(in: rect).compactMap { index in
            let frame = geometry.frame(index)
            guard frame.intersects(rect) else { return nil }
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = frame
            return attributes
        }
    }
    /// 单个项目的属性可直接计算，无须预先构造全量数组。
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let geometry = metrics
        guard indexPath.section == 0, (0..<geometry.count).contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(indexPath.item)
        return attributes
    }
    /// 普通滚动由进度驱动；尺寸变化时重新计算锚点。
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.size != collectionView?.bounds.size }
    /// 使用预测停止位置吸附，允许一次跨越多张照片。
    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint, withScrollingVelocity velocity: CGPoint) -> CGPoint {
        CGPoint(x: metrics.position(at: proposedContentOffset.x).rounded() * Metrics.stride, y: 0)
    }
    /// 保持附件物理顺序，避免 RTL 自动翻转。
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { false }
}
