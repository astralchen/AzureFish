import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAttachmentPagingLayoutTests {
    @Test func geometryIncludesOnlyInterPageSpacing() {
        guard #available(iOS 26.0, *) else { return }
        for count in [0, 1, 2, 20] {
            let metrics = AttachmentPagingLayout.Metrics(size: CGSize(width: 402, height: 874), count: count)
            #expect(metrics.contentSize.width == (count == 0 ? 0 : CGFloat(count * 402 + (count - 1) * 20)))
            #expect(metrics.contentSize.height == (count == 0 ? 0 : 874))
            #expect(metrics.offset(for: -1) == .zero)
            #expect(metrics.offset(for: 100) == metrics.offset(for: max(0, count - 1)))
            for index in 0..<count {
                #expect(metrics.frame(for: index).size == CGSize(width: 402, height: 874))
                #expect(metrics.index(nearestTo: metrics.offset(for: index)) == index)
                if index > 0 { #expect(metrics.frame(for: index).minX - metrics.frame(for: index - 1).maxX == 20) }
            }
            if count > 0 { #expect(metrics.frame(for: count - 1).maxX == metrics.contentSize.width) }
        }
    }

    @Test func snappingUsesDistanceVelocityAndSinglePageLimit() {
        guard #available(iOS 26.0, *) else { return }
        let metrics = AttachmentPagingLayout.Metrics(size: CGSize(width: 402, height: 874), count: 20)
        func target(_ displacement: CGFloat, _ velocity: CGFloat, start: Int = 5) -> Int {
            metrics.targetIndex(from: start, offset: CGPoint(x: metrics.offset(for: start).x + displacement, y: 0), velocity: velocity)
        }
        #expect(target(210, 0) == 5)
        #expect(target(212, 0) == 6)
        #expect(target(-212, 0) == 4)
        #expect(target(7, 2) == 5)
        #expect(target(8, 0.35) == 6)
        #expect(target(-8, -0.35) == 4)
        #expect(target(300, -1) == 5)
        #expect(target(-300, 1) == 5)
        #expect(target(1800, 0) == 6)
        #expect(target(-1800, 0) == 4)
        #expect(target(-200, -2, start: 0) == 0)
        #expect(target(200, 2, start: 19) == 19)
    }

    @Test func layoutProvidesVisibleAttributesAndInvalidatesOnlySizeChanges() throws {
        guard #available(iOS 26.0, *) else { return }
        let layout = AttachmentPagingLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 402, height: 874), collectionViewLayout: layout)
        let source = PagingSource()
        collection.dataSource = source
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "page")
        collection.reloadData()
        collection.layoutIfNeeded()
        layout.prepare()
        #expect(layout.collectionViewContentSize.width == 8420)
        let page = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        #expect(page.frame == CGRect(x: 422, y: 0, width: 402, height: 874))
        #expect(layout.layoutAttributesForElements(in: CGRect(x: 402, y: 0, width: 20, height: 874))?.isEmpty == true)
        #expect(layout.layoutAttributesForElements(in: CGRect(x: 390, y: 0, width: 50, height: 874))?.count == 2)
        #expect(layout.layoutAttributesForItem(at: IndexPath(item: 20, section: 0)) == nil)
        #expect(!layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 50, y: 0, width: 402, height: 874)))
        #expect(layout.shouldInvalidateLayout(forBoundsChange: CGRect(x: 0, y: 0, width: 874, height: 402)))
        collection.contentOffset = CGPoint(x: 422 * 5 + 100, y: 0)
        layout.beginDragging(at: CGPoint(x: 422 * 5, y: 0))
        #expect(abs(layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 7000, y: 0), withScrollingVelocity: CGPoint(x: 2, y: 0)).x - CGFloat(422 * 6)) < 0.001)
        #expect(layout.dragTargetIndex == 6)
        layout.endDragging()
        #expect(layout.dragStartIndex == nil)
        source.count = 1
        collection.reloadData()
        collection.layoutIfNeeded()
        layout.prepare()
        #expect(layout.collectionViewContentSize.width == 402)
    }

    @Test func interruptedPagingRotationAndCloseChooseTheVisibleAttachment() throws {
        guard #available(iOS 26.0, *) else { return }
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        let items = (0..<20).map { _ in AttachmentPreviewItem(id: UUID(), url: base.url, thumbnailURL: base.thumbnailURL, title: "Photo", kind: .image) }
        let controller = AttachmentPreviewController(items: items, initialIndex: 4, playbackCoordinator: .init())
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true }
        controller.view.layoutIfNeeded()
        let width = controller.collectionView.bounds.width
        controller.select(18, animated: true)
        controller.select(12, animated: true)
        #expect(controller.pendingPageIndex == 12)
        controller.scrollViewDidEndScrollingAnimation(controller.collectionView)
        #expect(controller.pendingPageIndex == 12)
        controller.view.frame.size = CGSize(width: 874, height: 402)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(controller.currentIndex == 12)
        #expect(abs(controller.collectionView.contentOffset.x - CGFloat(12 * 894)) < 0.001)
        #expect(controller.pendingPageIndex == nil)
        controller.collectionView.contentOffset.x = 12 * 894 + 600
        controller.scrollViewWillBeginDragging(controller.collectionView)
        #expect(controller.currentIndex == 13)
        controller.collectionView.contentOffset.x = 13 * 894 + 100
        controller.view.frame.size = CGSize(width: width, height: 874)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(controller.currentIndex == 13)
        #expect(controller.collectionView.contentOffset.x == 13 * (width + 20))
        controller.select(17, animated: true)
        controller.collectionView.contentOffset = controller.pagingLayout.offset(for: 15)
        controller.closeTapped()
        #expect(controller.currentIndex == 15)
        #expect(!controller.isHorizontalPaging)
    }
}

/// 布局集成测试使用的最小数据源，不参与 Demo 的 ListKit 路由。
@MainActor
private final class PagingSource: NSObject, UICollectionViewDataSource {
    var count = 20
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath)
    }
}
