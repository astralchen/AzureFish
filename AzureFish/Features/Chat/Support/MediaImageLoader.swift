import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// 已完成后台解码的图像；原图方向由 UIImage 的 orientation 保留，避免再次分配旋转位图。
nonisolated struct MediaDecodedImage: Sendable {
    /// 完整像素位图。
    let image: CGImage
    /// 原件 EXIF 方向；缩略图已应用方向时为 up。
    let orientation: CGImagePropertyOrientation
    /// 由文件内容识别多帧 GIF，不能仅凭扩展名判断。
    var isAnimatedGIF = false
}

/// 页面共享的有界图片加载器；普通请求只读调用者提供的缩略图 URL。
@MainActor
final class MediaImageLoader {
    /// 缩略图如何满足目标矩形。
    nonisolated enum Mode: String, Sendable { case fit, fill }
    /// 合并请求使用的完整键，不包含易变化的视图身份。
    nonisolated struct Key: Hashable, Sendable {
        /// 输入文件 URL。
        let url: URL
        /// 目标像素宽度。
        let width: Int
        /// 目标像素高度。
        let height: Int
        /// 裁剪模式。
        let mode: Mode
    }
    /// 一个消费者的可取消句柄。
    struct Request {
        /// 合并请求键。
        let key: Key
        /// 消费者身份。
        let id: UUID
    }
    /// 在途解码与有效消费者。
    private struct Pending {
        /// 防止旧任务覆盖同键新任务。
        let generation: UUID
        /// 持有调度槽位直到真正完成的任务。
        let task: Task<Void, Never>
        /// 同键消费者。
        var consumers: [UUID: (UIImage?) -> Void]
    }
    /// 页面所有图片处理共用的调度器。
    let scheduler: MediaWorkScheduler
    #if MEDIA_BENCHMARK
    /// 仅性能构建接收原图真正设置到预览页的通知；不持有页面或原图。
    var benchmarkOriginalDisplayed: ((URL, CGSize) -> Void)?
    #endif
    /// 已解码缩略图及其像素成本。
    private var cache: [Key: UIImage] = [:]
    /// 从最久未使用到最近使用的缓存键。
    private var recency: [Key] = []
    /// 当前缓存实际像素成本，不包含视图持有的图像。
    private(set) var cachedCost = 0
    /// 缓存预算为 16 MiB。
    private let costLimit = 16 * 1024 * 1024
    /// 尚未完成的合并请求。
    private var pending: [Key: Pending] = [:]
    /// 内存警告观察令牌。
    private var memoryObserver: NSObjectProtocol?
    /// 供规模与生命周期验证的请求数。
    var pendingCount: Int { pending.count }
    /// 供合并请求回归验证的实际解码次数。
    private(set) var decodeCount = 0

    /// 创建页面服务，并在内存警告时释放可回收缓存。
    init(scheduler: MediaWorkScheduler? = nil) {
        self.scheduler = scheduler ?? MediaWorkScheduler(limit: MediaWorkScheduler.pageLimit)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearCache() }
            }
    }

    /// 请求已按目标像素准备的缩略图，缓存命中同步回填；其他结果回到主 actor。
    func load(url: URL, size: CGSize, mode: Mode = .fill, completion: @escaping (UIImage?) -> Void) -> Request? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let key = Key(url: url, width: Int(ceil(min(size.width, 16384))), height: Int(ceil(min(size.height, 16384))), mode: mode)
        if let image = cache[key] {
            recency.removeAll { $0 == key }; recency.append(key)
            completion(image)
            return nil
        }
        let request = Request(key: key, id: UUID())
        if pending[key] != nil { pending[key]?.consumers[request.id] = completion; return request }
        let generation = UUID()
        let scheduler = scheduler
        let task = Task { [weak self] in
            do {
                let decoded = try await scheduler.run(kind: .visible) { try await Self.decodeThumbnail(key) }
                guard !Task.isCancelled else { return }
                self?.finish(key: key, generation: generation, decoded: decoded)
            } catch {
                self?.finish(key: key, generation: generation, decoded: nil)
            }
        }
        decodeCount += 1
        pending[key] = Pending(generation: generation, task: task, consumers: [request.id: completion])
        return request
    }

    /// 方形缩略图条使用像素边长请求。
    func load(url: URL, pixels: Int, completion: @escaping (UIImage?) -> Void) -> Request? {
        load(url: url, size: CGSize(width: pixels, height: pixels), completion: completion)
    }

    /// 取消单个消费者，无人等待时取消底层任务。
    func cancel(_ request: Request?) {
        guard let request, var entry = pending[request.key] else { return }
        entry.consumers[request.id] = nil
        if entry.consumers.isEmpty { entry.task.cancel(); pending[request.key] = nil }
        else { pending[request.key] = entry }
    }

    /// 页面退出时停止全部缩略图请求，其他单个视图只能取消自己的句柄。
    func cancelAll() {
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
    }

    /// 文件删除后拒绝迟到结果并清除对应缓存。
    func invalidate(url: URL) {
        for key in Array(pending.keys) where key.url == url { pending.removeValue(forKey: key)?.task.cancel() }
        for key in Array(cache.keys) where key.url == url { removeCached(key) }
    }

    /// 释放所有可回收缩略图。
    func clearCache() { cache.removeAll(); recency.removeAll(); cachedCost = 0 }

    /// 只有当前代次可以缓存并通知消费者，超预算单图不缓存。
    private func finish(key: Key, generation: UUID, decoded: MediaDecodedImage?) {
        guard let entry = pending[key], entry.generation == generation else { return }
        pending[key] = nil
        let result = decoded.map(Self.makeImage)
        if let decoded, let result {
            let cost = decoded.image.bytesPerRow * decoded.image.height
            if cost <= costLimit {
                while cachedCost + cost > costLimit, let oldest = recency.first { removeCached(oldest) }
                cache[key] = result; cachedCost += cost; recency.append(key)
            }
        }
        entry.consumers.values.forEach { $0(result) }
    }

    /// 删除一个缓存并更新精确成本。
    private func removeCached(_ key: Key) {
        if let image = cache.removeValue(forKey: key)?.cgImage { cachedCost -= image.bytesPerRow * image.height }
        recency.removeAll { $0 == key }
    }

    /// 完整原图专用入口；受页面调度器的单原图约束，不加入缓存。
    func original(url: URL) async throws -> UIImage {
        try await originalContent(url: url).image
    }

    /// 原图与动画身份一次解码返回，避免预览再次打开文件检查类型。
    func originalContent(url: URL) async throws -> (image: UIImage, isAnimatedGIF: Bool) {
        let decoded = try await scheduler.run(kind: .original) { try await Self.decodeOriginal(url) }
        try Task.checkCancellation()
        return (Self.makeImage(decoded), decoded.isAnimatedGIF)
    }

    /// 在后台按显示矩形下采样，并应用方向、立即解码，保留透明通道。
    @concurrent static func decodeThumbnail(_ key: Key) async throws -> MediaDecodedImage {
        let interval = MediaPerformance.signposter.beginInterval("ThumbnailDecode", id: MediaPerformance.signposter.makeSignpostID())
        defer { MediaPerformance.signposter.endInterval("ThumbnailDecode", interval) }
        assert(!Thread.isMainThread, "媒体解码必须离开主线程")
        try Task.checkCancellation()
        let result: MediaDecodedImage = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(key.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw CocoaError(.fileReadCorruptFile) }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let w = orientation >= 5 ? height.doubleValue : width.doubleValue
            let h = orientation >= 5 ? width.doubleValue : height.doubleValue
            guard w > 0, h > 0 else { throw CocoaError(.fileReadCorruptFile) }
            let ratios = (Double(key.width) / w, Double(key.height) / h)
            let scale = min(1, key.mode == .fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1))
            let maximum = max(1, ceil(max(w, h) * scale))
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum
            ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            return MediaDecodedImage(image: image, orientation: .up)
        }
        try Task.checkCancellation()
        return result
    }

    /// 原始分辨率解码，禁止设置缩略图尺寸上限；同步调用实际返回前一直持有调度槽位。
    @concurrent static func decodeOriginal(_ url: URL) async throws -> MediaDecodedImage {
        let interval = MediaPerformance.signposter.beginInterval("OriginalDecode", id: MediaPerformance.signposter.makeSignpostID())
        defer { MediaPerformance.signposter.endInterval("OriginalDecode", interval) }
        assert(!Thread.isMainThread, "媒体解码必须离开主线程")
        try Task.checkCancellation()
        let result: MediaDecodedImage = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw CocoaError(.fileReadCorruptFile) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let value = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            return MediaDecodedImage(image: image, orientation: CGImagePropertyOrientation(rawValue: value) ?? .up,
                isAnimatedGIF: CGImageSourceGetType(source) == UTType.gif.identifier as CFString && CGImageSourceGetCount(source) > 1)
        }
        try Task.checkCancellation()
        return result
    }

    /// 将已解码位图包装为正确方向的 UIKit 图像，不复制像素。
    private static func makeImage(_ decoded: MediaDecodedImage) -> UIImage {
        let orientation: UIImage.Orientation
        switch decoded.orientation {
        case .up: orientation = .up
        case .upMirrored: orientation = .upMirrored
        case .down: orientation = .down
        case .downMirrored: orientation = .downMirrored
        case .left: orientation = .left
        case .leftMirrored: orientation = .leftMirrored
        case .right: orientation = .right
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        return UIImage(cgImage: decoded.image, scale: 1, orientation: orientation)
    }

    /// 析构取消仍在等待的任务，不延长页面生命周期。
    isolated deinit {
        pending.values.forEach { $0.task.cancel() }
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
    }
}
