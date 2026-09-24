import Foundation
import ImageIO
import PhotosUI
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import AzureFish

/// 验证真实像素、请求合并与取消期间的资源所有权。
@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMediaPipelineTests {
    /// 可显式释放的异步测试门，不阻塞协作线程池。
    @MainActor final class Gate {
        /// 已进入门的任务数量。
        var arrivals = 0
        /// 等待测试继续的任务。
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// 暂停任务直到测试释放。
        func wait() async {
            arrivals += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        /// 按到达顺序释放一项或全部任务。
        func release(all: Bool = false) {
            if all { let values = waiters; waiters.removeAll(); values.forEach { $0.resume() } }
            else if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
    }

    /// 等待异步条件，失败时给出有限超时，避免测试永久挂起。
    private func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(condition())
    }

    /// 创建明确像素尺寸与透明通道的 PNG，可附加 EXIF 方向。
    private func fixture(width: Int = 4096, height: Int = 1024, orientation: Int = 1) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.red.withAlphaComponent(0.5).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func fullResolutionIsExclusiveToOriginalEntryAndPreservesAlpha() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let full = try await MediaImageLoader.decodeOriginal(url)
        #expect(full.image.width == 4096)
        #expect(full.image.height == 1024)
        #expect(full.image.alphaInfo != .none && full.image.alphaInfo != .noneSkipLast)
        let fit = try await MediaImageLoader.decodeThumbnail(.init(url: url, width: 100, height: 100, mode: .fit))
        let fill = try await MediaImageLoader.decodeThumbnail(.init(url: url, width: 100, height: 100, mode: .fill))
        #expect(fit.image.width == 100 && fit.image.height == 25)
        #expect(fill.image.width == 400 && fill.image.height == 100)
    }

    @Test func bundledHEICRetainsNativePixelsAndPreviewNeverFallsBackForThumbnail() async throws {
        guard #available(iOS 26.0, *) else { return }
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let url = bundle.appendingPathComponent("preview-image-21.heic")
        let full = try await MediaImageLoader.decodeOriginal(url)
        #expect(full.image.width == 4032 && full.image.height == 3024)
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let loader = MediaImageLoader()
        page.configure(.init(id: UUID(), url: url, thumbnailURL: nil, title: "", kind: .image), imageLoader: loader)
        page.layoutIfNeeded()
        #expect(loader.pendingCount == 0 && loader.decodeCount == 0)
        #expect(page.imageView.image == nil)
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        #expect(page.imageView.image?.cgImage?.width == 4032)
        page.suspendImages()
        page.setNeedsLayout()
        page.layoutIfNeeded()
        #expect(page.imageView.image == nil && loader.pendingCount == 0)
        #expect(loader.cachedCost == 0)
    }

    @Test func importAppliesOrientationAndKeepsOriginalBytes() async throws {
        guard #available(iOS 17.0, *) else { return }
        let url = try fixture(orientation: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let thumbnail = url.deletingLastPathComponent().appendingPathComponent("thumb.jpg")
        let metadata = try await MediaImportProcessor.makeMetadata(originalURL: url, thumbnailURL: thumbnail, isVideo: false)
        #expect(metadata.pixelSize == CGSize(width: 1024, height: 4096))
        #expect(try Data(contentsOf: url) == before)
        let decoded = try await MediaImageLoader.decodeOriginal(thumbnail)
        #expect(decoded.image.width == 320 && decoded.image.height == 1280)
        let original = try await MediaImageLoader().original(url: url)
        #expect(original.imageOrientation == .right)
        #expect(original.size == CGSize(width: 1024, height: 4096))
    }

    @Test func sharedRequestCancellationCacheAndInvalidation() async throws {
        let url = try fixture(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let loader = MediaImageLoader()
        var cancelled = false
        var delivered: UIImage?
        let first = loader.load(url: url, pixels: 90) { _ in cancelled = true }
        _ = loader.load(url: url, pixels: 90) { delivered = $0 }
        loader.cancel(first)
        try await until { delivered != nil }
        #expect(!cancelled)
        #expect(loader.decodeCount == 1)
        #expect(loader.cachedCost > 0 && loader.cachedCost <= 16 * 1024 * 1024)
        var cached: UIImage?
        _ = loader.load(url: url, pixels: 90) { cached = $0 }
        #expect(cached === delivered)
        #expect(loader.decodeCount == 1)
        loader.invalidate(url: url)
        #expect(loader.cachedCost == 0)
        delivered = nil
        _ = loader.load(url: url, pixels: 90) { delivered = $0 }
        try await until { delivered != nil }
        #expect(loader.decodeCount == 2)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(loader.cachedCost == 0)
    }

    @Test func cancelledRunningOriginalHoldsSlotUntilWorkActuallyReturns() async throws {
        let scheduler = MediaWorkScheduler()
        let originalGate = Gate()
        let otherGate = Gate()
        let first = Task { try await scheduler.run(kind: .original) { await originalGate.wait() } }
        let second = Task { try await scheduler.run(kind: .original) { await originalGate.wait() } }
        let third = Task { try await scheduler.run(kind: .visible) { await otherGate.wait() } }
        try await until { scheduler.activeCount == 2 && scheduler.waitingCount == 1 }
        #expect(originalGate.arrivals == 1)
        first.cancel()
        for _ in 0..<10 { await Task.yield() }
        #expect(scheduler.activeCount == 2)
        #expect(originalGate.arrivals == 1)
        originalGate.release()
        try await until { originalGate.arrivals == 2 }
        originalGate.release()
        otherGate.release()
        _ = await first.result
        try await second.value
        try await third.value
        #expect(scheduler.activeCount == 0 && scheduler.waitingCount == 0)
    }

    /// 取消准备中的 warm 驱动后，迟到的哈希结果不得重新登记文件导入。
    @Test func benchmarkPreparationCancellationDoesNotRestartImport() async throws {
        #if MEDIA_BENCHMARK
        guard #available(iOS 26.0, *) else { return }
        let chat = ChatViewController()
        chat.loadViewIfNeeded()
        let driver = MediaConcurrencyBenchmark(chat: chat, scenarioOverride: "warm")
        driver.install()
        let work = driver.task
        await Task.yield()
        driver.cancel()
        await work?.value
        #expect(chat.photoController.entries.isEmpty)
        #expect(chat.photoController.activeImports.isEmpty)
        #expect(chat.photoController.pendingImports.isEmpty)
        #expect((chat.navigationItem.rightBarButtonItem?.customView as? UIButton)?.accessibilityValue != "ready")
        chat.attachmentStore.removeAll()
        #endif
    }

    /// 从测试运行器验证页面默认注入，避免命令行参数未送达时两组实际使用同一上限。
    @Test func benchmarkLaunchConfigurationReachesPageLoader() async throws {
        #if MEDIA_BENCHMARK
        guard let raw = ProcessInfo.processInfo.environment["MEDIA_BENCHMARK_EXPECTED_LIMIT"], let expected = Int(raw) else { return }
        #expect(MediaWorkScheduler.pageLimit == expected)
        let loader = MediaImageLoader()
        let gate = Gate()
        let tasks = (0..<3).map { _ in Task { try await loader.scheduler.run(kind: .visible) { await gate.wait() } } }
        try await until { gate.arrivals == expected && loader.scheduler.waitingCount == 3 - expected }
        tasks.forEach { $0.cancel() }
        gate.release(all: true)
        for task in tasks { _ = await task.result }
        #expect(loader.scheduler.activeCount == 0)
        #endif
    }

    /// 两种候选配置都必须保持真实执行上限，取消运行项不能提前放行排队项。
    @Test(arguments: [1, 2]) func candidateLimitsBoundActualWork(limit: Int) async throws {
        let scheduler = MediaWorkScheduler(limit: limit)
        let gate = Gate()
        let tasks = (0..<6).map { _ in Task { try await scheduler.run(kind: .importing) { await gate.wait() } } }
        try await until { gate.arrivals == limit && scheduler.waitingCount == 6 - limit }
        tasks.forEach { $0.cancel() }
        try await until { scheduler.waitingCount == 0 }
        #expect(scheduler.activeCount == limit)
        gate.release(all: true)
        for task in tasks { _ = await task.result }
        #expect(scheduler.activeCount == 0)
        #expect(gate.arrivals == limit)
    }

    @Test func visibleWorkPrecedesQueuedImportAndWaitingCancellationNeverRuns() async throws {
        let scheduler = MediaWorkScheduler(limit: 1)
        let gate = Gate()
        let blocker = Task { try await scheduler.run(kind: .importing) { await gate.wait() } }
        try await until { gate.arrivals == 1 }
        let cancelled = Task { try await scheduler.run(kind: .importing) { await gate.wait() } }
        let background = Task { try await scheduler.run(kind: .importing) { await gate.wait() } }
        let visible = Task { try await scheduler.run(kind: .visible) { await gate.wait() } }
        try await until { scheduler.waitingCount == 3 }
        cancelled.cancel()
        try await until { scheduler.waitingCount == 2 }
        gate.release()
        try await until { gate.arrivals == 2 }
        visible.cancel()
        gate.release()
        try await until { gate.arrivals == 3 }
        gate.release()
        _ = await cancelled.result
        _ = await visible.result
        try await blocker.value
        try await background.value
        #expect(gate.arrivals == 3)
    }

    @Test func previewLoadsCompleteOriginalThenReleasesItOffscreen() async throws {
        guard #available(iOS 26.0, *) else { return }
        let original = try fixture()
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let thumbnail = original.deletingLastPathComponent().appendingPathComponent("thumb.jpg")
        _ = try await MediaImportProcessor.makeMetadata(originalURL: original, thumbnailURL: thumbnail, isVideo: false)
        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let loader = MediaImageLoader()
        page.configure(.init(id: UUID(), url: original, thumbnailURL: thumbnail, title: "", kind: .image), imageLoader: loader)
        page.layoutIfNeeded()
        try await until { page.imageView.image != nil }
        #expect(!page.hasOriginalImage)
        #expect((page.imageView.image?.cgImage?.width ?? 0) <= 1280)
        page.imageScrollView.zoomScale = 2
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        #expect(page.imageView.image?.cgImage?.width == 4096)
        #expect(page.imageScrollView.zoomScale == 2)
        page.suspendImages()
        #expect(!page.hasOriginalImage && page.imageView.image == nil)
        #expect(loader.cachedCost < 4096 * 1024 * 4)
        page.resumeImages()
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        page.reset()
        #expect(page.imageView.image == nil)
    }

    /// 检查实际像素自动变化，而非只检查动画标记；复用后的旧帧不能覆盖静态照片。
    @Test func gifPreviewAutoplaysPreservesZoomAndStopsWhenReused() async throws {
        let still = try fixture(width: 48, height: 32)
        defer { try? FileManager.default.removeItem(at: still.deletingLastPathComponent()) }
        // 故意不使用 .gif 扩展名，确认由真实文件类型识别。
        let gif = still.deletingLastPathComponent().appendingPathComponent("animation.data")
        let destination = try #require(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil))
        let context = try #require(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for color in [UIColor.red, .green, .blue] {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try await MediaImageLoader.decodeOriginal(gif)
        #expect(decoded.isAnimatedGIF)
        let staticDecoded = try await MediaImageLoader.decodeOriginal(still)
        #expect(!staticDecoded.isAnimatedGIF)

        let page = AttachmentPreviewPage(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        let item = AttachmentPreviewItem(id: UUID(), url: gif, thumbnailURL: nil, title: "GIF", kind: .image)
        page.configure(item)
        page.layoutIfNeeded()
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        func pixels() -> Data? { page.imageView.image?.cgImage?.dataProvider?.data as Data? }
        let first = try #require(pixels())
        page.imageScrollView.zoomScale = 2
        let frame = page.imageView.frame
        try await until { pixels() != first }
        #expect(page.imageScrollView.zoomScale == 2)
        #expect(page.imageView.frame == frame)
        page.suspendImages()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(page.imageView.image == nil)
        page.resumeImages()
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        let resumed = try #require(pixels())
        try await until { pixels() != resumed }
        page.configure(.init(id: UUID(), url: still, thumbnailURL: nil, title: "静态照片", kind: .image))
        page.setOriginalActive(true)
        try await until { page.hasOriginalImage }
        let stillPixels = try #require(pixels())
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(pixels() == stillPixels)
        page.reset()
    }

    /// 普通照片无需查询实况对象类型；同时提供 MOV 与 GIF 时，电影表示不得改变照片身份。
    @Test(arguments: ["preview-image-01.gif", "preview-image-02.png", "video-only", "image-only"])
    func photoRepresentationTakesPrecedenceOverAlternateMovie(name: String) async throws {
        guard #available(iOS 26.0, *) else { return }
        let bundle = try #require(Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle"))
        let movie = bundle.appendingPathComponent("live-photo.mov")
        let provider = NSItemProvider()
        if name != "image-only" {
            provider.registerFileRepresentation(forTypeIdentifier: UTType.quickTimeMovie.identifier, fileOptions: [], visibility: .all) { completion in
                completion(movie, false, nil)
                return Progress(totalUnitCount: 1)
            }
        }
        let isVideo = name == "video-only"
        let source = isVideo ? movie : bundle.appendingPathComponent(name == "image-only" ? "preview-image-02.png" : name)
        if !isVideo {
            let type = name.hasSuffix("gif") ? UTType.gif : UTType.png
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                completion(source, false, nil)
                return Progress(totalUnitCount: 1)
            }
        }
        #expect(!provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier))
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let controller = PhotoPickerController(attachmentStore: store)
        let entry = PhotoPickerController.DraftEntry(assetIdentifier: nil)
        controller.entries.append(entry)
        controller.pendingImports.append(.init(provider: provider, entry: entry, generation: controller.generation))
        controller.drainImports()
        try await until { controller.activeImports.isEmpty }
        let media = try #require(controller.draftAttachment?.items.first)
        #expect(media.kind.isVideo == isVideo)
        #expect(media.isAnimatedImage == name.hasSuffix("gif"))
        #expect(!media.isLivePhoto)
        #expect(try Data(contentsOf: media.originalFileURL) == Data(contentsOf: source))
        let preview = try #require(AttachmentPreviewItem.prepare(.mediaGroup(.init(items: [media]))).first)
        #expect(preview.kind == (isVideo ? .video : .image))
        controller.discardDraft()
    }

    @Test(arguments: [1, 2]) func allTwentyImportsCompleteInSelectionOrderAndCommitFiles(limit: Int) async throws {
        guard #available(iOS 17.0, *) else { return }
        let source = try fixture(width: 256, height: 128)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let store = PageAttachmentStore()
        let controller = PhotoPickerController(attachmentStore: store, imageLoader: MediaImageLoader(scheduler: MediaWorkScheduler(limit: limit)))
        let gate = Gate()
        for index in 0..<20 {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier, fileOptions: [], visibility: .all) { completion in
                Task { @MainActor in await gate.wait(); completion(source, false, nil) }
                return Progress(totalUnitCount: 1)
            }
            let entry = PhotoPickerController.DraftEntry(assetIdentifier: "complete-\(index)")
            controller.entries.append(entry)
            controller.pendingImports.append(.init(provider: provider, entry: entry, generation: controller.generation))
        }
        let ids = controller.entries.map(\.id)
        controller.drainImports()
        for batch in 1...10 {
            try await until { gate.arrivals == batch * 2 }
            #expect(controller.activeImports.count <= 2)
            gate.waiters.removeLast().resume()
            gate.release()
        }
        try await until { controller.activeImports.isEmpty }
        let draft = try #require(controller.draftAttachment)
        #expect(draft.items.map(\.id) == ids)
        #expect(controller.commitDraft())
        #expect(controller.entries.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil).count == 40)
        store.removeAll()
    }

    @Test(arguments: [1, 2]) func twentyProviderImportsAreBoundedAndCancellationCleansLateCopies(limit: Int) async throws {
        guard #available(iOS 17.0, *) else { return }
        let source = try fixture(width: 256, height: 128)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let store = PageAttachmentStore()
        let controller = PhotoPickerController(attachmentStore: store, imageLoader: MediaImageLoader(scheduler: MediaWorkScheduler(limit: limit)))
        let gate = Gate()
        for index in 0..<20 {
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.image.identifier, fileOptions: [], visibility: .all) { completion in
                Task { @MainActor in
                    await gate.wait()
                    completion(source, false, nil)
                }
                return Progress(totalUnitCount: 1)
            }
            let entry = PhotoPickerController.DraftEntry(assetIdentifier: "fixture-\(index)")
            controller.entries.append(entry)
            controller.pendingImports.append(.init(provider: provider, entry: entry, generation: controller.generation))
        }
        let orderedIDs = controller.entries.map(\.id)
        controller.drainImports()
        try await until { gate.arrivals == 2 }
        #expect(controller.activeImports.count == 2)
        #expect(controller.pendingImports.count == 18)
        // 首批反序完成仍必须保留原始选择顺序。
        gate.waiters.removeLast().resume()
        gate.release()
        try await until { gate.arrivals == 4 }
        #expect(controller.entries.map(\.id) == orderedIDs)
        #expect(controller.entries.prefix(2).allSatisfy { $0.presentation.mediaItem != nil })
        controller.discardDraft()
        gate.release(all: true)
        try await until { controller.activeImports.isEmpty }
        #expect(controller.entries.isEmpty && controller.pendingImports.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
        store.removeAll()
    }
}
