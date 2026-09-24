import AVFoundation
import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAttachmentPreviewTests {
    /// 拖动暂隐控制层但不改写沉浸偏好；取消必须恢复命中，且不改变主图布局和滑块身份。
    @Test func seekingPresentationRestoresControlsAfterCancellation() throws {
        guard #available(iOS 26.0, *) else { return }
        let item = AttachmentPreviewItem(id: UUID(), url: URL(fileURLWithPath: "/unused-video.mp4"),
            thumbnailURL: nil, title: "视频", kind: .video)
        let controller = AttachmentPreviewController(items: [item], initialIndex: 0, playbackCoordinator: .init())
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        let frame = controller.collectionView.frame
        let slider = controller.chrome.playbackControls.slider
        let center = slider.convert(CGPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: controller.view)
        slider.sendActions(for: .touchDown)
        controller.view.layoutIfNeeded()
        #expect(controller.chrome.isScrubbingPresentation)
        #expect(controller.chrome.controlsVisible)
        #expect(!controller.chrome.closeButton.isUserInteractionEnabled)
        #expect(controller.collectionView.frame == frame)
        #expect(abs(slider.convert(CGPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: controller.view).y - center.y) < 0.5)
        slider.sendActions(for: .touchCancel)
        controller.view.layoutIfNeeded()
        #expect(!controller.chrome.isScrubbingPresentation)
        #expect(controller.chrome.closeButton.isUserInteractionEnabled)
        #expect(controller.chrome.playbackControls.slider === slider)
        #expect(controller.collectionView.frame == frame)
        controller.toggleControls()
        #expect(!controller.chrome.controlsVisible)
    }
    /// 首次视频仅在页面展开完成后启动，后续出现回调不得覆盖手动暂停。
    @Test func initialVideoAutoplaysOnlyAfterFirstAppearance() throws {
        guard #available(iOS 26.0, *) else { return }
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let item = AttachmentPreviewItem(id: UUID(), url: bundle.appendingPathComponent("preview-video-01.mp4"),
            thumbnailURL: nil, title: "视频", kind: .video)
        let controller = AttachmentPreviewController(items: [item], initialIndex: 0, playbackCoordinator: .init())
        controller.loadViewIfNeeded()
        #expect(controller.playback.activationTask == nil)
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        controller.viewDidAppear(false)
        #expect(controller.playback.activationTask != nil)
        controller.playback.pause()
        controller.viewDidAppear(false)
        #expect(controller.playback.activationTask == nil)
        #expect(!controller.playback.isPlaying)
    }
    /// 翻页停稳才自动播放视频，缩略图中间项、音频和暂停后的布局更新不得重新启动。
    @Test func videoAutoplayWaitsForSettledUserNavigation() throws {
        guard #available(iOS 26.0, *) else { return }
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let url = bundle.appendingPathComponent("preview-video-01.mp4")
        let items = [base,
            AttachmentPreviewItem(id: UUID(), url: url, thumbnailURL: nil, title: "视频 1", kind: .video),
            AttachmentPreviewItem(id: UUID(), url: url, thumbnailURL: nil, title: "视频 2", kind: .video),
            AttachmentPreviewItem(id: UUID(), url: url, thumbnailURL: nil, title: "音频", kind: .audio)]
        let controller = AttachmentPreviewController(items: items, initialIndex: 0, playbackCoordinator: .init())
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { controller.completeDismissal(); window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        controller.toggleControls()
        let collection = controller.collectionView
        // 模拟旧翻页动画已接近下一页、但尚未正式提交时被新手势打断。
        collection.contentOffset = controller.pagingLayout.offset(for: 1)
        controller.scrollViewWillBeginDragging(collection)
        #expect(controller.playback.activationTask == nil)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        #expect(controller.currentIndex == 1)
        #expect(controller.playback.activationTask != nil)
        #expect(!controller.chrome.controlsVisible)
        controller.playback.pause()
        controller.select(1, animated: false)
        controller.view.frame.size = CGSize(width: 874, height: 402)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(controller.playback.activationTask == nil)
        controller.chrome.thumbnailStrip.didBeginScrubbing?()
        for index in [2, 1, 2] {
            controller.chrome.thumbnailStrip.didScrubToItem?(index)
            #expect(controller.playback.player == nil)
            #expect(controller.playback.activationTask == nil)
        }
        controller.chrome.thumbnailStrip.didEndScrubbing?(2)
        #expect(controller.playback.activationTask != nil)
        controller.chrome.thumbnailStrip.didBeginScrubbing?()
        #expect(controller.playback.activationTask == nil)
        controller.chrome.thumbnailStrip.didScrubToItem?(3)
        controller.chrome.thumbnailStrip.didEndScrubbing?(3)
        #expect(controller.currentIndex == 3)
        #expect(controller.playback.activationTask == nil)
    }
    /// 视频快照独立持有封面，不复制或重新绑定视频图层；缺图时交给转场淡入淡出。
    @Test func videoTransitionUsesStaticCoverWithoutCopyingPlayerLayer() throws {
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let item = AttachmentPreviewItem(id: UUID(), url: URL(fileURLWithPath: "/unused-video.mp4"),
            thumbnailURL: nil, title: "视频", kind: .video)
        page.configure(item)
        let player = AVPlayer()
        page.bind(player: player)
        #expect(page.transitionSnapshot(afterScreenUpdates: true) == nil)
        let cover = try #require(UIImage(systemName: "play.fill"))
        page.imageView.image = cover
        for updates in [true, false] {
            let snapshot = try #require(page.transitionSnapshot(afterScreenUpdates: updates) as? UIImageView)
            #expect(snapshot !== page.imageView)
            #expect(snapshot.image === cover)
            #expect(snapshot.layer.sublayers?.isEmpty ?? true)
            #expect(page.playerLayer.player === player)
        }
    }
    /// 时间和状态回调重复提供同一播放器时，不应重新接入视频输出。
    @Test func bindingSamePlayerDoesNotReconnectVideoOutput() {
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let first = AVPlayer(), second = AVPlayer()
        var changes = 0
        let observer = page.playerLayer.observe(\.player, options: [.new]) { _, _ in
            // 本测试只在主 Actor 同步绑定播放器，KVO 计数沿用同一隔离边界。
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { observer.invalidate() }
        for _ in 0..<30 { page.bind(player: first) }
        #expect(changes == 1)
        page.bind(player: second)
        #expect(changes == 2)
        page.bind(player: nil)
        page.bind(player: nil)
        #expect(changes == 3)
        #expect(page.playerLayer.player == nil)
    }
    @Test func thumbnailStripCentersSelectionAndReusesCellsAfterResize() throws {
        guard #available(iOS 26.0, *) else { return }
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let thumbnail = try #require(base.thumbnailURL)
        let items = try (0..<1000).map { index in
            let url = directory.appendingPathComponent("thumbnail-\(index).png")
            try FileManager.default.linkItem(at: thumbnail, to: url)
            return AttachmentPreviewItem(id: UUID(), url: base.url, thumbnailURL: url, title: "", kind: .image)
        }
        let strip = AttachmentThumbnailStripView(items: items, selectedIndex: 999)
        func layout(_ width: CGFloat) {
            strip.frame = CGRect(x: 0, y: 0, width: width, height: 64)
            strip.setNeedsLayout()
            strip.layoutIfNeeded()
            strip.collectionView.layoutIfNeeded()
        }
        func checkCenter(_ index: Int) throws {
            let collection = strip.collectionView
            let cell = try #require(collection.cellForItem(at: IndexPath(item: index, section: 0)) as? AttachmentThumbnailStripCell)
            #expect(abs(cell.frame.midX - collection.bounds.midX) < 0.5)
            #expect(cell.isSelected)
            cell.layoutIfNeeded()
            #expect(cell.imageView.frame.size == CGSize(width: 30, height: 30))
            #expect(collection.visibleCells.count < 30)
            #expect(strip.imageLoader.pendingCount <= collection.visibleCells.count)
        }
        for width: CGFloat in [370, 220, 560] { layout(width); try checkCenter(999) }
        var requested: Int?
        strip.didSelectItem = { requested = $0 }
        _ = strip.collectionView(strip.collectionView, shouldSelectItemAt: IndexPath(item: 998, section: 0))
        #expect(requested == 998)
        #expect(strip.selectedIndex == 999)
        strip.select(-1)
        layout(370)
        try checkCenter(0)
        strip.select(2000)
        layout(370)
        try checkCenter(999)
        #expect(requested == 998)
    }

    @Test func emptyThumbnailStripHasNoSelectionOrCallback() {
        guard #available(iOS 26.0, *) else { return }
        let strip = AttachmentThumbnailStripView(items: [])
        var callbacks = 0
        strip.didSelectItem = { _ in callbacks += 1 }
        strip.select(10)
        strip.frame = CGRect(x: 0, y: 0, width: 370, height: 64)
        strip.layoutIfNeeded()
        #expect(strip.selectedIndex == nil)
        #expect(strip.stripLayout.collectionViewContentSize == .zero)
        #expect(callbacks == 0)
    }

    @Test func fileRoutingUsesUTTypeAndActualFileContents() throws {
        guard #available(iOS 26.0, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Hello 世界".utf8).write(to: url)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.plainText.identifier) == .text("Hello 世界"))
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.pdf.identifier) == .pdf)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.png.identifier) == .image)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.mpeg4Movie.identifier) == .video)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.mp3.identifier) == .audio)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: "org.openxmlformats.wordprocessingml.document") == .quickLook)
        try Data([0xff, 0xfe, 0x41, 0x00]).write(to: url)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.plainText.identifier) == .text("A"))
        try Data([0xff, 0x80, 0x01]).write(to: url)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.plainText.identifier) == .quickLook)
        try Data(repeating: 65, count: 5 * 1024 * 1024 + 1).write(to: url)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.plainText.identifier) == .quickLook)
        try FileManager.default.removeItem(at: url)
        #expect(AttachmentPreviewItem.fileKind(url: url, typeIdentifier: UTType.pdf.identifier) == .unavailable)
    }

    @Test func currentPageRemainsSelectedAfterSizeChange() {
        guard #available(iOS 26.0, *) else { return }
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        let items = (0..<20).map { index in
            AttachmentPreviewItem(id: UUID(), url: base.url, thumbnailURL: base.thumbnailURL, title: "\(index)", kind: .image)
        }
        let controller = AttachmentPreviewController(items: items, initialIndex: 4, playbackCoordinator: .init())
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.view.layoutIfNeeded()
        #expect(controller.currentIndex == 4)
        #expect(controller.collectionView.contentOffset.x == CGFloat(4 * (402 + 20)))
        controller.select(0, animated: false)
        controller.view.layoutIfNeeded()
        #expect(controller.collectionView.contentOffset.x == 0)
        controller.select(18, animated: false)
        controller.view.frame.size = CGSize(width: 874, height: 402)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(controller.currentIndex == 18)
        #expect(abs(controller.collectionView.contentOffset.x - CGFloat(18 * (874 + 20))) < 0.5)
        controller.select(80, animated: false)
        #expect(controller.currentIndex == 19)
        controller.select(-2, animated: false)
        #expect(controller.currentIndex == 0)
        controller.completeDismissal()
    }

    @Test func dismissalThresholdRequiresDownwardIntent() {
        guard #available(iOS 26.0, *) else { return }
        #expect(!AttachmentPreviewPolicy.shouldDismiss(distance: 20, velocity: 1200, height: 874))
        #expect(!AttachmentPreviewPolicy.shouldDismiss(distance: 100, velocity: -1200, height: 874))
        #expect(AttachmentPreviewPolicy.shouldDismiss(distance: 25, velocity: 901, height: 874))
        #expect(AttachmentPreviewPolicy.shouldDismiss(distance: 193, velocity: 0, height: 874))
    }

    @Test func textSelectionAndImageZoomPreventDismissal() {
        guard #available(iOS 26.0, *) else { return }
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let base = ConversationPreviewData.attachmentPreviewItems[0]
        page.configure(.init(id: base.id, url: base.url, thumbnailURL: nil, title: "Text", kind: .text("Selectable text")))
        page.layoutIfNeeded()
        #expect(page.permitsDismissal)
        page.documentTopInset = 240
        page.layoutIfNeeded()
        #expect(page.textView?.frame.minY == 240)
        page.textView?.selectedRange = NSRange(location: 0, length: 4)
        #expect(!page.permitsDismissal)
        page.textView?.selectedRange = NSRange(location: 0, length: 0)
        page.textView?.contentOffset.y = 50
        #expect(!page.permitsDismissal)
        page.configure(base)
        page.layoutIfNeeded()
        page.imageScrollView.zoomScale = 2
        #expect(!page.permitsDismissal)
        page.reset()
    }

    @Test func resettingPageRejectsLateImageLoad() async {
        guard #available(iOS 26.0, *) else { return }
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        page.configure(ConversationPreviewData.attachmentPreviewItems[0])
        page.reset()
        for _ in 0..<20 { await Task.yield() }
        #expect(page.itemID == nil)
        #expect(page.imageView.image == nil)
        #expect(page.playerLayer.player == nil)
    }

    @Test func closingTwiceReleasesPlaybackAndCallsCompletionOnce() {
        guard #available(iOS 26.0, *) else { return }
        let controller = AttachmentPreviewController(items: ConversationPreviewData.attachmentPreviewItems, initialIndex: 0, playbackCoordinator: .init())
        controller.loadViewIfNeeded()
        var count = 0
        controller.didClose = { count += 1 }
        controller.completeDismissal()
        controller.completeDismissal()
        #expect(count == 1)
        #expect(controller.playback.player == nil)
    }
    @Test func detachedSourceFallsBackAndRestoresPresenter() async throws {
        guard #available(iOS 26.0, *) else { return }
        let presenter = UIViewController()
        let window = try makeVisibleTestWindow(rootViewController: presenter)
        defer { window.isHidden = true; window.rootViewController = nil }
        let preview = AttachmentPreviewController(items: ConversationPreviewData.attachmentPreviewItems, initialIndex: 0, playbackCoordinator: .init())
        let detachedCard = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        var resolvedForDismissal = false
        var completions = 0
        preview.sourceResolver = { _, synchronizing in
            resolvedForDismissal = resolvedForDismissal || synchronizing
            return synchronizing ? detachedCard : nil
        }
        preview.didClose = { completions += 1 }
        await withCheckedContinuation { continuation in
            presenter.present(preview, animated: true) { continuation.resume() }
        }
        #expect(preview.view.window === window)
        await withCheckedContinuation { continuation in
            preview.dismiss(animated: true) { continuation.resume() }
        }
        #expect(resolvedForDismissal)
        #expect(completions == 1)
        #expect(presenter.presentedViewController == nil)
        #expect(preview.view.superview == nil)
        #expect(presenter.view.alpha == 1)
        #expect(detachedCard.alpha == 1)
    }

}
