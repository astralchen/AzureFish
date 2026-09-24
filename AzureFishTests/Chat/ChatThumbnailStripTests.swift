import Testing
import UIKit
@testable import AzureFish

/// 胶片条的连续几何、手势所有权和沉浸加载回归。
@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatThumbnailStripTests {
    @Test func geometryMatchesReferenceAtEveryQuarterStep() {
        for p: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let m = AttachmentThumbnailStripLayout.Metrics(size: CGSize(width: 402, height: 64), count: 20, position: 5 + p)
            #expect(abs(m.frame(5).width - (30 - 10 * p)) < 0.001)
            #expect(abs(m.frame(6).width - (20 + 10 * p)) < 0.001)
            #expect(abs(m.frame(5).minX - m.frame(4).maxX - (13 - 10 * p)) < 0.001)
            #expect(abs(m.frame(6).minX - m.frame(5).maxX - 13) < 0.001)
            #expect(abs(m.frame(7).minX - m.frame(6).maxX - (3 + 10 * p)) < 0.001)
            #expect(abs(m.frame(9).minX - m.frame(8).maxX - 3) < 0.001)
            let center = m.frame(5).midX * (1 - p) + m.frame(6).midX * p - m.offset.x
            #expect(abs(center - 201) < 0.001)
        }
    }

    @Test func boundariesContinuityAndVisibleQueriesStayBounded() {
        for count in [1, 2, 1000] {
            for width: CGFloat in [220, 402, 560] {
                for index in [0, count - 1] {
                    let m = AttachmentThumbnailStripLayout.Metrics(size: CGSize(width: width, height: 64), count: count, position: CGFloat(index))
                    #expect(abs(m.frame(index).midX - m.offset.x - width / 2) < 0.001)
                    #expect(m.frame(index).width == 30)
                    #expect(m.candidates(in: CGRect(origin: m.offset, size: m.size)).count < 35)
                }
            }
        }
        for position: CGFloat in [0.999999, 1, 1.000001] {
            let m = AttachmentThumbnailStripLayout.Metrics(size: CGSize(width: 402, height: 64), count: 1000, position: position)
            let exact = AttachmentThumbnailStripLayout.Metrics(size: m.size, count: m.count, position: 1)
            for index in 0..<12 { #expect(abs(m.frame(index).minX - exact.frame(index).minX) < 0.001) }
        }
    }

    @Test func layoutOnlyReturnsIntersectingAttributesAndSnapsAcrossManyItems() throws {
        let layout = AttachmentThumbnailStripLayout()
        let collection = UICollectionView(frame: CGRect(x: 0, y: 0, width: 402, height: 64), collectionViewLayout: layout)
        let source = Source()
        collection.dataSource = source
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        collection.reloadData()
        layout.position = 500.5
        collection.layoutIfNeeded()
        let rect = CGRect(x: 500.5 * 23, y: 0, width: 402, height: 64)
        let attributes = try #require(layout.layoutAttributesForElements(in: rect))
        #expect(attributes.count < 25)
        #expect(attributes.allSatisfy { $0.frame.intersects(rect) })
        let expected = (0..<1000).filter { layout.metrics.frame($0).intersects(rect) }
        #expect(attributes.map(\.indexPath.item) == expected)
        #expect(layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 800.7 * 23, y: 0), withScrollingVelocity: CGPoint(x: 4, y: 0)).x == CGFloat(801 * 23))
        #expect(layout.layoutAttributesForItem(at: IndexPath(item: 1000, section: 0)) == nil)
    }

    @Test func scrubbingOwnsProgressAndHostFeedbackDoesNotRecenter() {
        guard #available(iOS 26.0, *) else { return }
        let strip = makeStrip()
        var indices: [Int] = []
        var ended: Int?
        strip.didScrubToItem = { index in indices.append(index); strip.select(index); strip.setPagingPosition(CGFloat(index)) }
        strip.didEndScrubbing = { ended = $0 }
        strip.scrollViewWillBeginDragging(strip.collectionView)
        strip.collectionView.contentOffset.x = 5.6 * 23
        strip.scrollViewDidScroll(strip.collectionView)
        #expect(abs(strip.pagingPosition * 23 - 5.6 * 23) < 0.5)
        #expect(indices == [6])
        strip.scrollViewDidScroll(strip.collectionView)
        #expect(indices == [6])
        strip.scrollViewDidEndDragging(strip.collectionView, willDecelerate: false)
        #expect(ended == 6)
        #expect(strip.selectedIndex == 6)
        #expect(strip.collectionView.contentOffset.x == CGFloat(6 * 23))
        #expect(!strip.isScrubbing)
    }

    @Test func hiddenStripStoresProgressWithoutLoadingAndRestoresAnchor() {
        guard #available(iOS 26.0, *) else { return }
        let strip = makeStrip()
        strip.setContentActive(false)
        let before = strip.collectionView.contentOffset
        strip.select(19)
        strip.setPagingPosition(18.25)
        #expect(strip.collectionView.contentOffset == before)
        #expect(strip.imageLoader.pendingCount == 0)
        #expect(strip.accessibilityElementsHidden)
        #expect(!strip.point(inside: CGPoint(x: 201, y: 32), with: nil))
        strip.setContentActive(true)
        #expect(abs(strip.collectionView.contentOffset.x - 18.25 * 23) < 0.5)
        #expect(!strip.point(inside: CGPoint(x: 201, y: 5), with: nil))
        #expect(strip.point(inside: CGPoint(x: 201, y: 32), with: nil))
        #expect(strip.layer.mask is CAGradientLayer)
    }

    @Test func hostContinuouslyTracksPagingAndImmersionDoesNotResizePage() {
        guard #available(iOS 26.0, *) else { return }
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        let items = (0..<20).map { _ in AttachmentPreviewItem(id: UUID(), url: base.url, thumbnailURL: base.thumbnailURL, title: "", kind: .image) }
        let host = AttachmentPreviewController(items: items, initialIndex: 0, playbackCoordinator: .init())
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        host.view.layoutIfNeeded()
        let frame = host.collectionView.frame
        host.collectionView.contentOffset.x = host.pagingLayout.metrics.stride * 0.25
        host.scrollViewDidScroll(host.collectionView)
        #expect(abs(host.chrome.thumbnailStrip.pagingPosition - 0.25) < 0.001)
        #expect(host.chrome.thumbnailStrip.selectedIndex == 0)
        host.toggleControls()
        host.select(8, animated: false)
        host.view.layoutIfNeeded()
        #expect(!host.chrome.controlsVisible)
        #expect(host.chrome.accessibilityElementsHidden)
        #expect(host.collectionView.frame == frame)
        #expect(!host.chrome.thumbnailStrip.isContentActive)
        host.toggleControls()
        #expect(host.chrome.controlsVisible)
        #expect(host.chrome.thumbnailStrip.selectedIndex == 8)
        #expect(host.chrome.thumbnailStrip.pagingPosition == 8)
        #expect(host.collectionView.frame == frame)
    }

    @Test func imageDecodeCancellationAndCellReuseRejectStaleResults() async throws {
        guard #available(iOS 26.0, *) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("image.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        try #require(image.pngData()).write(to: url)
        let decoded = try await MediaImageLoader.decodeThumbnail(.init(url: url, width: 90, height: 90, mode: .fill)).image
        #expect(decoded.width == 180 && decoded.height == 90)
        let bad = directory.appendingPathComponent("bad.png")
        try Data("broken".utf8).write(to: bad)
        await #expect(throws: (any Error).self) {
            try await MediaImageLoader.decodeThumbnail(.init(url: bad, width: 90, height: 90, mode: .fill))
        }
        let loader = MediaImageLoader()
        var cancelledCallback = false
        let request = loader.load(url: url, pixels: 90) { _ in cancelledCallback = true }
        loader.cancel(request)
        #expect(loader.pendingCount == 0)
        let cell = AttachmentThumbnailStripCell()
        let item = AttachmentPreviewItem(id: UUID(), url: url, thumbnailURL: url, title: "", kind: .image)
        cell.configure(item: item, index: 0, count: 2, loader: loader, scale: 3)
        cell.loadIfNeeded()
        cell.prepareForReuse()
        let missing = AttachmentPreviewItem(id: UUID(), url: bad, thumbnailURL: nil, title: "", kind: .video)
        cell.configure(item: missing, index: 1, count: 2, loader: loader, scale: 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!cancelledCallback)
        #expect(cell.itemIndex == 1)
        #expect(cell.imageView.image?.isSymbolImage == true)
        #expect(loader.pendingCount == 0)
    }

    /// 使用现有本地预览图片，独立于照片库权限。
    @available(iOS 26.0, *)
    private func makeStrip() -> AttachmentThumbnailStripView {
        let strip = AttachmentThumbnailStripView(items: Array(repeating: ConversationPreviewData.attachmentPreviewItems[0], count: 20))
        strip.frame = CGRect(x: 0, y: 0, width: 402, height: 64)
        strip.layoutIfNeeded()
        strip.collectionView.layoutIfNeeded()
        return strip
    }
    /// 千项数据源验证查询复杂度，不创建全量视图。
    private final class Source: NSObject, UICollectionViewDataSource {
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1000 }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
    }
}
