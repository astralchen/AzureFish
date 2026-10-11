import Foundation
import AzureFishAPI
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized)
/// 覆盖图片页几何、复用、缓存、迟到响应和失权撤回；不代替真实手势 UI 回归。
struct MomentsPhotoTests {
    @Test func paginationGapSelectionRotationAndRevocation() throws {
        for count in [1, 4, 9] {
            var post = MomentsPreviewData.posts[0]; post.images = Array(post.images.prefix(count))
            let controller = MomentsPhotoViewController(runtime: MomentsRuntime(preview: [post], user: post.author.id), post: post, index: count / 2)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); controller.view.layoutIfNeeded()
            let layout = controller.pagingLayout, collection = controller.collection
            #expect(layout.collectionViewContentSize.width == CGFloat(count * 390 + (count - 1) * 20))
            #expect(collection.contentOffset.x == CGFloat(count / 2 * 410))
            #expect(controller.index == count / 2)
            if count > 1 {
                collection.contentOffset.x = 205
                let visible = try #require(layout.layoutAttributesForElements(in: collection.bounds))
                #expect(visible.count == 2)
                #expect(visible[1].frame.minX - visible[0].frame.maxX == 20)
                controller.scrollViewWillBeginDragging(collection)
                collection.contentOffset.x = 390
                _ = layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 1500, y: 0), withScrollingVelocity: CGPoint(x: 1, y: 0))
                controller.scrollViewDidEndDecelerating(collection)
                #expect(controller.index == 1)
                #expect(collection.contentOffset.x == 410)
            }
            let selected = controller.index
            controller.view.frame.size = CGSize(width: 1024, height: 768); controller.view.layoutIfNeeded()
            #expect(controller.index == selected)
            #expect(collection.contentOffset.x == CGFloat(selected * 1044))
            #expect(layout.metrics.size == CGSize(width: 1024, height: 768))
            if count > 1 {
                collection.contentOffset.x = 0
                controller.scrollViewWillBeginDragging(collection)
                collection.contentOffset.x = 700
                controller.view.frame.size = CGSize(width: 390, height: 844); controller.view.layoutIfNeeded()
                #expect(controller.index == 1)
                #expect(collection.contentOffset.x == 410)
                #expect(layout.dragStartIndex == nil)
            }
            controller.invalidateImages()
            #expect(controller.loader.retained.isEmpty)
            #expect(collection.isHidden)
            #expect(!controller.select(offset: 1))
        }
    }
    @Test func pageReusePreservesZoomOnlyForSameAssetAndResizesAroundCenter() throws {
        let page = MomentsPhotoPage(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let image = try #require(UIImage(data: MomentsPreviewData.image(1)))
        page.configure(assetID: "one", index: 0, state: .image(image)); page.layoutIfNeeded()
        #expect(page.imageView.frame.width == 390)
        #expect(abs(page.imageView.frame.height - 292.5) < 1)
        page.scroll.setZoomScale(3, animated: false)
        page.scroll.contentOffset = CGPoint(x: 300, y: 10)
        let before = CGPoint(x: (page.scroll.contentOffset.x + 195) / page.scroll.contentSize.width,
                             y: (page.scroll.contentOffset.y + 422) / page.scroll.contentSize.height)
        page.configure(assetID: "one", index: 0, state: .image(image))
        page.frame.size = CGSize(width: 720, height: 600); page.layoutIfNeeded()
        #expect(abs(page.scroll.zoomScale - 3) < 0.01)
        let after = CGPoint(x: (page.scroll.contentOffset.x + 360) / page.scroll.contentSize.width,
                            y: (page.scroll.contentOffset.y + 300) / page.scroll.contentSize.height)
        #expect(abs(before.x - after.x) < 0.01 && abs(before.y - after.y) < 0.01)
        #expect(page.scroll.panGestureRecognizer.isEnabled)
        page.prepareForReuse()
        #expect(page.imageView.image == nil && page.assetID == nil)
        #expect(page.scroll.zoomScale == 1 && !page.scroll.panGestureRecognizer.isEnabled)
        page.configure(assetID: "two", index: 1, state: .loading); page.layoutIfNeeded()
        #expect(page.imageView.image == nil && page.assetID == "two")
    }
    @Test func closeThresholdAndZoomAllowsPaging() throws {
        #expect(!MomentsPhotoViewController.shouldClose(distance: 40, velocity: 1200, height: 844))
        #expect(MomentsPhotoViewController.shouldClose(distance: 41, velocity: 901, height: 844))
        #expect(!MomentsPhotoViewController.shouldClose(distance: 159, velocity: 0, height: 844))
        #expect(MomentsPhotoViewController.shouldClose(distance: 161, velocity: 0, height: 844))
        #expect(MomentsPhotoViewController.shouldClose(distance: 81, velocity: 0, height: 400))
        let controller = MomentsPhotoViewController(runtime: MomentsPreviewData.runtime(), post: MomentsPreviewData.posts[0], index: 0)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); controller.view.layoutIfNeeded()
        let page = try #require(controller.currentPage)
        page.scroll.setZoomScale(3, animated: false)
        #expect(controller.collection.isScrollEnabled)
        #expect(controller.select(offset: 1)); #expect(controller.index == 1)
        controller.toggleControls(); #expect(controller.controlsHidden)
        controller.invalidateImages(); #expect(!controller.controlsHidden)
    }
    @Test func loadingWindowRetryCancellationAndLateResponses() async throws {
        let requests = PhotoRequests()
        let loader = MomentsPhotoLoader(assets: MomentsPreviewData.images) { asset in try await requests.fetch(asset.id) }
        defer { loader.stop(); requests.finishAll() }
        let bytes = MomentsPreviewData.image(1)
        loader.updateWindow(around: 0)
        try await waitUntil { requests.pending.count == 2 }
        loader.updateWindow(around: 4)
        try await waitUntil { requests.pending.count == 5 }
        requests.finish("1", with: .success(bytes)); requests.finish("2", with: .success(bytes))
        requests.finish("4", with: .success(bytes)); requests.finish("6", with: .success(bytes))
        requests.finish("5", with: .failure(NSError(domain: "fixture", code: 1)))
        try await waitUntil { if case .failed = loader.states[4] { return true }; return false }
        #expect(loader.retained == [3, 4, 5]); #expect(loader.states[0] == nil && loader.states[1] == nil)
        loader.retry(4); try await waitUntil { requests.pending.count == 1 }
        requests.finish("5", with: .success(bytes))
        try await waitUntil { if case .image = loader.states[4] { return true }; return false }
        loader.updateWindow(around: 8); try await waitUntil { requests.pending.count == 2 }
        loader.stop(); requests.finishAll()
        for _ in 0..<10 { await Task.yield() }
        #expect(loader.states.isEmpty && loader.retained.isEmpty)
    }
    @Test func revisitingPagesReusesCompletedImagesAndInflightRequests() async throws {
        let requests = PhotoRequests(), cache = MomentsPhotoCache()
        let loader = MomentsPhotoLoader(assets: MomentsPreviewData.images, cache: cache) { try await requests.fetch($0.id) }
        defer { loader.stop(); requests.finishAll() }
        loader.updateWindow(around: 0)
        try await waitUntil { requests.pending.count == 2 }
        loader.updateWindow(around: 4)
        try await waitUntil { requests.pending.count == 5 }
        loader.updateWindow(around: 0)
        for _ in 0..<10 { await Task.yield() }
        #expect(requests.calls["1"] == 1 && requests.calls["2"] == 1)
        let bytes = MomentsPreviewData.image(1)
        for id in ["1", "2", "4", "5", "6"] { requests.finish(id, with: .success(bytes)) }
        try await waitUntil { cache.image(for: MomentsPreviewData.images[4], target: "") != nil && cache.image(for: MomentsPreviewData.images[0], target: "") != nil }
        let first = try #require(cache.image(for: MomentsPreviewData.images[0], target: ""))
        for index in [8, 4, 0, 8, 0] { loader.updateWindow(around: index) }
        guard case .image(let returned) = loader.states[0] else { Issue.record("返回已加载页未同步命中缓存"); return }
        #expect(returned === first)
        try await waitUntil { requests.pending.count == 2 }
        #expect(requests.calls.values.allSatisfy { $0 == 1 })
        loader.stop(); requests.finishAll()
        for _ in 0..<10 { await Task.yield() }
        #expect(cache.image(for: MomentsPreviewData.images[8], target: "") == nil)
        #expect(loader.states.isEmpty)
    }

    @Test func cachedOriginalAndThumbnailAppearImmediatelyAndFailureKeepsThumbnail() async throws {
        let requests = PhotoRequests(), cache = MomentsPhotoCache()
        let assets = Array(MomentsPreviewData.images.prefix(2)), image = try #require(UIImage(data: MomentsPreviewData.image(1)))
        cache.insert(image, asset: assets[0], target: "post")
        let loader = MomentsPhotoLoader(assets: assets, target: "post", cache: cache, placeholder: { _ in image }) { try await requests.fetch($0.id) }
        defer { loader.stop(); requests.finishAll() }
        loader.updateWindow(around: 0)
        guard case .image(let original) = loader.states[0], case .preview(let thumbnail, nil) = loader.states[1] else {
            Issue.record("缓存未在首帧显示"); return
        }
        #expect(original === image && thumbnail === image)
        try await waitUntil { requests.pending.count == 1 }
        #expect(requests.calls["1"] == nil)
        requests.finish("2", with: .failure(NSError(domain: "fixture", code: 1)))
        try await waitUntil { if case .preview(_, .some) = loader.states[1] { return true }; return false }
        let page = MomentsPhotoPage(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        page.configure(assetID: "2", index: 1, state: loader.states[1]); page.layoutIfNeeded()
        #expect(page.imageView.image === image)
        loader.retry(1); try await waitUntil { requests.pending.count == 1 }
        #expect(requests.calls["2"] == 2)
        requests.finish("2", with: .success(MomentsPreviewData.image(2)))
        try await waitUntil { if case .image = loader.states[1] { return true }; return false }
        loader.stop()
        let reopened = MomentsPhotoLoader(assets: assets, target: "post", cache: cache) { try await requests.fetch($0.id) }
        defer { reopened.stop() }
        reopened.updateWindow(around: 1)
        guard case .image = reopened.states[0], case .image = reopened.states[1] else { Issue.record("重新打开未命中原图缓存"); return }
        for _ in 0..<10 { await Task.yield() }
        #expect(requests.calls["1"] == nil && requests.calls["2"] == 2)
    }

    @Test func previewCacheScopeEvictionAndAccountStop() async throws {
        let image = try #require(UIImage(data: MomentsPreviewData.image(1))), assets = MomentsPreviewData.images
        let cache = MomentsPhotoCache(countLimit: 2)
        for asset in assets.prefix(3) { cache.insert(image, asset: asset, target: "post") }
        #expect(cache.image(for: assets[0], target: "post") == nil)
        #expect(cache.image(for: assets[2], target: "post") === image)
        #expect(cache.image(for: assets[2], target: "other") == nil)
        var revised = assets[2]; revised.version += 1
        #expect(cache.image(for: revised, target: "post") == nil)
        cache.removeUnreferenced { asset, _ in asset.id != assets[2].id }
        #expect(cache.image(for: assets[2], target: "post") == nil)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(cache.image(for: assets[1], target: "post") == nil)
        let runtime = MomentsPreviewData.runtime(), post = MomentsPreviewData.posts[0]
        runtime.photoCache.insert(image, asset: assets[0], target: post.id)
        let controller = MomentsPhotoViewController(runtime: runtime, post: post, index: 0)
        controller.loadViewIfNeeded(); controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); controller.view.layoutIfNeeded()
        #expect(controller.currentPage?.imageView.image === image)
        await runtime.stop().value
        #expect(runtime.photoCache.image(for: assets[0], target: post.id) == nil)
        #expect(controller.loader.states.isEmpty && controller.collection.isHidden)
    }

    @Test func upgradingThumbnailKeepsZoomAndViewingCenter() throws {
        let page = MomentsPhotoPage(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let thumbnail = try #require(UIImage(data: MomentsPreviewData.image(1)))
        page.configure(assetID: "one", index: 0, state: .preview(thumbnail, failure: nil)); page.layoutIfNeeded()
        page.scroll.setZoomScale(3, animated: false); page.scroll.contentOffset = CGPoint(x: 300, y: 10)
        let before = page.scroll.contentOffset
        let full = try #require(UIImage(data: MomentsPreviewData.image(1, size: CGSize(width: 1600, height: 1200))))
        page.configure(assetID: "one", index: 0, state: .image(full)); page.layoutIfNeeded()
        #expect(page.imageView.image === full)
        #expect(abs(page.scroll.zoomScale - 3) < 0.01)
        #expect(abs(page.scroll.contentOffset.x - before.x) < 1 && abs(page.scroll.contentOffset.y - before.y) < 1)
    }

    @Test func zoomedImageHandsOffOnlyOutwardHorizontalDragsAtItsEdges() throws {
        let page = MomentsPhotoPage(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        page.configure(assetID: "one", index: 0, state: .image(try #require(UIImage(data: MomentsPreviewData.image(1)))))
        page.canTurnPage = { _ in true }; page.layoutIfNeeded()
        #expect(!page.shouldYieldPan(CGPoint(x: -500, y: 0)))
        page.scroll.setZoomScale(3, animated: false)
        page.scroll.contentOffset.x = 300
        #expect(!page.shouldYieldPan(CGPoint(x: -500, y: 0)))
        #expect(!page.shouldYieldPan(CGPoint(x: 500, y: 0)))
        page.scroll.contentOffset.x = -page.scroll.adjustedContentInset.left
        #expect(page.shouldYieldPan(CGPoint(x: 500, y: 0)))
        #expect(!page.shouldYieldPan(CGPoint(x: -500, y: 0)))
        page.scroll.contentOffset.x = page.scroll.contentSize.width - page.scroll.bounds.width + page.scroll.adjustedContentInset.right
        #expect(page.shouldYieldPan(CGPoint(x: -500, y: 0)))
        #expect(!page.shouldYieldPan(CGPoint(x: 500, y: 0)))
        #expect(!page.shouldYieldPan(CGPoint(x: -200, y: 500)))
        page.canTurnPage = { _ in false }
        #expect(!page.shouldYieldPan(CGPoint(x: -500, y: 0)))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        Issue.record("图片请求未在预期时间内完成")
    }
}

@MainActor
/// 由测试手动完成的图片请求，允许在取消后注入迟到响应以检查代次隔离。
private final class PhotoRequests {
    var pending: [(String, CheckedContinuation<Data, any Error>)] = []
    var calls: [String: Int] = [:]
    func fetch(_ id: String) async throws -> Data {
        calls[id, default: 0] += 1
        return try await withCheckedThrowingContinuation { pending.append((id, $0)) }
    }
    func finish(_ id: String, with result: Result<Data, any Error>) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(with: result)
    }
    func finishAll() {
        let old = pending; pending = []
        for (_, continuation) in old { continuation.resume(throwing: CancellationError()) }
    }
}
