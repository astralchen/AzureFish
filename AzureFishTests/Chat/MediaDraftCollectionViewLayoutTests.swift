import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized)
struct MediaDraftCollectionViewLayoutTests {
    @Test(arguments: [false, true])
    func delegateGeometryAndInvalidation(rtl: Bool) async throws {
        let fixture = try Fixture(rtl: rtl)
        defer { fixture.window.isHidden = true }
        fixture.widths = [0: 80, 1: 156, 2: 208]
        await fixture.apply([0, 1, 2])
        let frames = try (0..<3).map { try #require(fixture.layout.layoutAttributesForItem(at: .init(item: $0, section: 0))).frame }
        #expect(frames.map(\.width) == [80, 156, 208])
        #expect(frames.allSatisfy { $0.height == 156 && $0.minY == 0 })
        #expect(fixture.layout.collectionViewContentSize == CGSize(width: 460, height: 156))
        #expect(rtl ? frames[0].maxX == 458 : frames[0].minX == 2)
        #expect(rtl ? frames[0].minX - frames[1].maxX == 6 : frames[1].minX - frames[0].maxX == 6)
        let queries = fixture.sizeQueries
        fixture.collection.contentOffset.x = 50
        fixture.collection.layoutIfNeeded()
        #expect(fixture.sizeQueries == queries)
        fixture.collection.frame.size.width = 280
        fixture.collection.layoutIfNeeded()
        #expect(fixture.sizeQueries == queries)
        fixture.widths[1] = 120
        fixture.layout.invalidateMetrics()
        fixture.collection.layoutIfNeeded()
        fixture.layout.finishUpdates()
        #expect(fixture.layout.layoutAttributesForItem(at: .init(item: 1, section: 0))?.size.width == 120)
        fixture.layout.minimumLineSpacing = 10
        fixture.layout.sectionInset = UIEdgeInsets(top: 3, left: 4, bottom: 5, right: 8)
        fixture.collection.layoutIfNeeded()
        #expect(fixture.layout.collectionViewContentSize == CGSize(width: 440, height: 164))
        fixture.collection.semanticContentAttribute = rtl ? .forceLeftToRight : .forceRightToLeft
        fixture.layout.invalidateGeometry()
        fixture.collection.layoutIfNeeded()
        let first = try #require(fixture.layout.layoutAttributesForItem(at: .init(item: 0, section: 0))).frame
        #expect(rtl ? first.minX == 4 : first.maxX == 432)
    }

    @Test func itemSizeFallbackAndEmptySnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.window.isHidden = true }
        fixture.collection.delegate = nil
        fixture.layout.itemSize = CGSize(width: 100, height: 156)
        await fixture.apply([0, 1])
        #expect(fixture.layout.layoutAttributesForItem(at: .init(item: 1, section: 0))?.frame == CGRect(x: 108, y: 0, width: 100, height: 156))
        #expect(fixture.sizeQueries == 0)
        await fixture.apply([])
        #expect(fixture.layout.layoutAttributesForElements(in: fixture.collection.bounds)?.isEmpty == true)
        #expect(fixture.layout.layoutAttributesForItem(at: .init(item: 0, section: 0)) == nil)
        #expect(fixture.layout.collectionViewContentSize.width == 240)
        #expect(fixture.layout.updateAnchor == nil)
    }

    @Test func deletingAndMovingUsePreviousGeometryAndClearTransaction() async throws {
        let fixture = try Fixture()
        defer { fixture.window.isHidden = true }
        fixture.widths = [0: 80, 1: 120, 2: 160, 3: 100]
        await fixture.apply([0, 1, 2])
        let deletedFrame = try #require(fixture.layout.layoutAttributesForItem(at: .init(item: 1, section: 0))).frame
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems([2, 0, 3])
        fixture.layout.updateAnchor = .init(indexPath: .init(item: 2, section: 0), alignment: .trailing)
        fixture.layout.deletedFrames.removeAll()
        await fixture.source.apply(snapshot, animatingDifferences: true)
        #expect(!fixture.layout.deletedFrames.isEmpty)
        for frame in fixture.layout.deletedFrames { #expect(frame == deletedFrame) }
        fixture.layout.finishUpdates()
        #expect(fixture.layout.updateAnchor == nil)
        #expect((0..<3).map { fixture.layout.layoutAttributesForItem(at: .init(item: $0, section: 0))?.size.width } == [160, 80, 100])
        fixture.collection.contentOffset.x = 20
        await fixture.apply([2, 0, 3])
        #expect(fixture.collection.contentOffset.x == 20)
        #expect(fixture.layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 30, y: 0)).x == 30)
    }

    // 记录 UIKit 实际请求的退场几何。finalize 可能早于视觉动画结束，
    // 不能靠 sleep 后主动查询 disappearing attributes 来验证旧事务。
    private final class RecordingLayout: MediaDraftCollectionViewLayout {
        var deletedFrames: [CGRect] = []
        private var deletedPaths: Set<IndexPath> = []
        override func prepare(forCollectionViewUpdates updates: [UICollectionViewUpdateItem]) {
            super.prepare(forCollectionViewUpdates: updates)
            deletedPaths = Set(updates.filter { $0.updateAction == .delete }.compactMap(\.indexPathBeforeUpdate))
            if !deletedPaths.isEmpty {
                // 同一事务重复失效，仍应保留首次捕获的旧几何。
                invalidateMetrics()
                invalidateMetrics()
            }
        }
        override func finalLayoutAttributesForDisappearingItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            let result = super.finalLayoutAttributesForDisappearingItem(at: indexPath)
            if deletedPaths.contains(indexPath),
               let geometry = result?.copy() as? UICollectionViewLayoutAttributes {
                #expect(geometry.alpha == 0)
                #expect(geometry.transform == CGAffineTransform(scaleX: 0.96, y: 0.96))
                // frame 包含退场缩放；恢复副本的 transform 后检查布局原始几何。
                geometry.transform = .identity
                deletedFrames.append(geometry.frame)
            }
            return result
        }
        override func finalizeCollectionViewUpdates() {
            super.finalizeCollectionViewUpdates()
            deletedPaths.removeAll()
        }
    }

    private final class Fixture: NSObject, MediaDraftCollectionViewLayoutDelegate {
        let layout = RecordingLayout()
        let collection: UICollectionView
        let window: UIWindow
        var source: UICollectionViewDiffableDataSource<Int, Int>!
        var widths: [Int: CGFloat] = [:]
        var sizeQueries = 0

        init(rtl: Bool = false) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            collection = UICollectionView(frame: CGRect(x: 0, y: 100, width: 240, height: 156), collectionViewLayout: layout)
            super.init()
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            window.rootViewController!.view.addSubview(collection)
            collection.contentInsetAdjustmentBehavior = .never
            collection.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
            collection.delegate = self
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            source = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collection) { collection, index, _ in
                collection.dequeueReusableCell(withReuseIdentifier: "cell", for: index)
            }
        }
        func apply(_ ids: [Int]) async {
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(ids)
            await withCheckedContinuation { continuation in
                source.apply(snapshot, animatingDifferences: false) { continuation.resume() }
            }
            collection.layoutIfNeeded()
            layout.finishUpdates()
        }
        func collectionView(_ collectionView: UICollectionView, layout: MediaDraftCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> CGSize {
            sizeQueries += 1
            guard let id = source.itemIdentifier(for: indexPath) else { return layout.itemSize }
            return CGSize(width: widths[id] ?? 80, height: 156)
        }
    }
}
