import os
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// 不持有页面状态的媒体处理器，所有重处理显式离开主 actor。
@available(iOS 16.0, *)
nonisolated enum MediaImportProcessor {
    /// 从已复制原件提取的媒体尺寸、类型和动态图像信息。
    struct ImportedMetadata: Sendable {
        /// 用于展示宽高比计算的媒体像素尺寸。
        let pixelSize: CGSize
        /// 原件的图像或视频类型及有效时长。
        let kind: MediaKind
        /// 指示原件包含多帧图像的布尔值。
        let isAnimatedImage: Bool
    }

    /// 读取媒体原件元数据，并将静态预览写入指定缩略图位置。
    ///
    /// - Parameters:
    ///   - originalURL: 页面拥有的媒体原件。
    ///   - thumbnailURL: JPEG 缩略图的输出位置。
    ///   - isVideo: 是否按视频轨道和时长读取原件。
    /// - Returns: 媒体展示所需的尺寸、类型和动态图像标记。
    /// - Throws: 原件损坏、元数据无效、解码或缩略图写入失败时产生的错误。
    @concurrent static func makeMetadata(
        originalURL: URL,
        thumbnailURL: URL,
        isVideo: Bool
    ) async throws -> ImportedMetadata {
        assert(!Thread.isMainThread, "媒体元数据与缩略图生成必须离开主线程")
        let interval = MediaPerformance.signposter.beginInterval("ImportMetadata", id: MediaPerformance.signposter.makeSignpostID())
        defer { MediaPerformance.signposter.endInterval("ImportMetadata", interval) }
        try Task.checkCancellation()
        if isVideo {
            let asset = AVURLAsset(url: originalURL)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first,
                  duration.isNumeric,
                  duration.seconds.isFinite,
                  duration.seconds > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let (naturalSize, preferredTransform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            let transformedSize = CGRect(origin: .zero, size: naturalSize)
                .applying(preferredTransform)
                .standardized
                .size
            guard transformedSize.width > 0, transformedSize.height > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            let posterTime = CMTime(
                seconds: min(0.1, duration.seconds / 2),
                preferredTimescale: 600
            )
            let request = PosterGeneration(generator: generator)
            let image = try await withTaskCancellationHandler {
                try await request.image(at: posterTime)
            } onCancel: {
                Task { await request.cancel() }
            }
            try Task.checkCancellation()
            try writeJPEG(image, to: thumbnailURL)
            return ImportedMetadata(
                pixelSize: transformedSize,
                kind: .video(duration: duration.seconds),
                isAnimatedImage: false
            )
        }

        return try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1280,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try Task.checkCancellation()
            try writeJPEG(thumbnail, to: thumbnailURL)
            try Task.checkCancellation()
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            return ImportedMetadata(
                pixelSize: orientation >= 5
                    ? CGSize(width: height.doubleValue, height: width.doubleValue)
                    : CGSize(width: width.doubleValue, height: height.doubleValue),
                kind: .image,
                isAnimatedImage: CGImageSourceGetCount(source) > 1
            )
        }
    }

    /// 以 0.84 压缩质量将图像写入 JPEG 文件；无法创建或完成写入时抛出错误。
    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// 独占非 Sendable 的视频截图器，串行处理启动和取消；实际 SDK 回调返回后才结束等待。
@available(iOS 16.0, *)
private actor PosterGeneration {
    /// 从创建方转移所有权，外部不再访问同一个截图器。
    private let generator: AVAssetImageGenerator
    /// 取消可能先于图像请求进入 Actor，记录后禁止迟到启动。
    private var isCancelled = false

    /// 接收已完成配置的截图器，保留原有资产和尺寸设置。
    init(generator: sending AVAssetImageGenerator) {
        self.generator = generator
    }

    /// 等待唯一图像请求；取消后仍等待 SDK 回调，避免后台解码尚未退出就释放导入槽。
    func image(at time: CMTime) async throws -> CGImage {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
    }

    /// 在同一 Actor 中取消当前请求；由 SDK 的完成回调恢复图像等待。
    func cancel() {
        isCancelled = true
        generator.cancelAllCGImageGeneration()
    }
}
