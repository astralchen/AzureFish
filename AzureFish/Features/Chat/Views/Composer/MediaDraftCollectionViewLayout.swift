import UIKit

@MainActor
protocol MediaDraftCollectionViewLayoutDelegate: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, layout: MediaDraftCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize
}

final class MediaDraftLayoutInvalidationContext: UICollectionViewLayoutInvalidationContext {
    var invalidateItemSizes = false
    var invalidateContainerGeometry = false
}

/// 单 section、单行横向布局。数量来自 collection view，尺寸来自 delegate；不持有业务模型。
class MediaDraftCollectionViewLayout: UICollectionViewLayout {
    var itemSize = CGSize(width: 80, height: 156) {
        didSet { if itemSize != oldValue { invalidateMetrics() } }
    }
    var minimumLineSpacing: CGFloat = 6 {
        didSet { if minimumLineSpacing != oldValue { invalidateGeometry() } }
    }
    var sectionInset = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 2) {
        didSet { if sectionInset != oldValue { invalidateGeometry() } }
    }
    var reducesMotion = false

    struct Anchor {
        enum Alignment { case leading, trailing, screenPosition(CGFloat) }
        let indexPath: IndexPath
        let alignment: Alignment
    }
    var updateAnchor: Anchor?
    private var attributes: [UICollectionViewLayoutAttributes] = []
    // attributes 发布后只读；prepare 创建新对象，旧数组无需逐项复制。
    private var previousAttributes: [UICollectionViewLayoutAttributes]?
    private var inserted: Set<IndexPath> = []
    private var deleted: Set<IndexPath> = []
    private var movedFrom: [IndexPath: IndexPath] = [:]
    private var sizes: [CGSize] = []
    private var contentSize: CGSize = .zero
    private var needsGeometry = true
    private var needsSizes = true
    private var preparedWidth: CGFloat?
    private var preparedDirection: UIUserInterfaceLayoutDirection?

    override class var invalidationContextClass: AnyClass { MediaDraftLayoutInvalidationContext.self }

    func invalidateMetrics() {
        let context = MediaDraftLayoutInvalidationContext()
        context.invalidateItemSizes = true
        invalidateLayout(with: context)
    }

    func invalidateGeometry() {
        let context = MediaDraftLayoutInvalidationContext()
        context.invalidateContainerGeometry = true
        invalidateLayout(with: context)
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        let custom = context as? MediaDraftLayoutInvalidationContext
        let metricsChanged = context.invalidateEverything || context.invalidateDataSourceCounts
            || custom?.invalidateItemSizes == true || !(context.invalidatedItemIndexPaths ?? []).isEmpty
        if metricsChanged {
            if previousAttributes == nil { previousAttributes = attributes }
            needsSizes = true
        }
        if metricsChanged || custom?.invalidateContainerGeometry == true { needsGeometry = true }
        super.invalidateLayout(with: context)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let direction = collectionView.effectiveUserInterfaceLayoutDirection
        let available = max(0, collectionView.bounds.width - collectionView.adjustedContentInset.left
            - collectionView.adjustedContentInset.right)
        if count != sizes.count { needsSizes = true }
        if preparedWidth != available || preparedDirection != direction { needsGeometry = true }
        guard needsGeometry || needsSizes else { return }
        if needsSizes {
            let delegate = collectionView.delegate as? MediaDraftCollectionViewLayoutDelegate
            sizes = (0..<count).map { index in
                let size = delegate?.collectionView(collectionView, layout: self,
                    sizeForItemAt: IndexPath(item: index, section: 0)) ?? itemSize
                return size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
                    ? size : itemSize
            }
        }
        let total = sectionInset.left + sizes.reduce(0) { $0 + $1.width }
            + CGFloat(max(0, count - 1)) * minimumLineSpacing + sectionInset.right
        let width = max(total, available)
        let rtl = direction == .rightToLeft
        var distance = rtl ? sectionInset.right : sectionInset.left
        attributes = sizes.enumerated().map { index, size in
            let value = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            value.frame = CGRect(x: rtl ? width - distance - size.width : distance,
                                 y: sectionInset.top, width: size.width, height: size.height)
            distance += size.width + minimumLineSpacing
            return value
        }
        contentSize = CGSize(width: width, height: sectionInset.top + (sizes.map(\.height).max() ?? 0) + sectionInset.bottom)
        preparedWidth = available
        preparedDirection = direction
        needsGeometry = false
        needsSizes = false
    }

    override var collectionViewContentSize: CGSize { contentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        (context as? MediaDraftLayoutInvalidationContext)?.invalidateContainerGeometry = true
        return context
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        inserted = Set(updateItems.filter { $0.updateAction == .insert }.compactMap(\.indexPathAfterUpdate))
        deleted = Set(updateItems.filter { $0.updateAction == .delete }.compactMap(\.indexPathBeforeUpdate))
        movedFrom = Dictionary(uniqueKeysWithValues: updateItems.compactMap {
            guard $0.updateAction == .move, let before = $0.indexPathBeforeUpdate,
                  let after = $0.indexPathAfterUpdate else { return nil }
            return (after, before)
        })
    }

    override func initialLayoutAttributesForAppearingItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if inserted.contains(indexPath), let value = layoutAttributesForItem(at: indexPath)?.copy() as? UICollectionViewLayoutAttributes {
            value.alpha = 0
            if !reducesMotion { value.transform = CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.96, y: 0.96) }
            return value
        }
        if let before = movedFrom[indexPath], let old = previousAttributes, old.indices.contains(before.item),
           let value = old[before.item].copy() as? UICollectionViewLayoutAttributes {
            value.indexPath = indexPath
            return value
        }
        return super.initialLayoutAttributesForAppearingItem(at: indexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard deleted.contains(indexPath), let old = previousAttributes, old.indices.contains(indexPath.item),
              let value = old[indexPath.item].copy() as? UICollectionViewLayoutAttributes else {
            return super.finalLayoutAttributesForDisappearingItem(at: indexPath)
        }
        value.alpha = 0
        if !reducesMotion { value.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
        return value
    }

    func contentOffset(for anchor: Anchor) -> CGPoint? {
        guard let collectionView, let frame = layoutAttributesForItem(at: anchor.indexPath)?.frame else { return nil }
        let inset = collectionView.adjustedContentInset
        let rtl = collectionView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left = frame.minX - inset.left - sectionInset.left
        let right = frame.maxX - collectionView.bounds.width + inset.right + sectionInset.right
        let x: CGFloat
        switch anchor.alignment {
        case .leading: x = rtl ? right : left
        case .trailing: x = rtl ? left : right
        case .screenPosition(let position): x = frame.minX - position
        }
        let minimum = -inset.left
        let maximum = max(minimum, contentSize.width - collectionView.bounds.width + inset.right)
        return CGPoint(x: min(maximum, max(minimum, x)), y: collectionView.contentOffset.y)
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        updateAnchor.flatMap { contentOffset(for: $0) } ?? super.targetContentOffset(forProposedContentOffset: proposedContentOffset)
    }

    /// 动画 finalize 与无动画 snapshot completion 共用，允许重复收尾。
    func finishUpdates() {
        inserted.removeAll()
        deleted.removeAll()
        movedFrom.removeAll()
        previousAttributes = nil
        updateAnchor = nil
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        finishUpdates()
    }
}
