@preconcurrency import AVFoundation
import AzureFishAPI
import Foundation
import UIKit

/// 为朋友圈导出兼容 MP4；输入和输出均由账号临时文件租约管理。
@MainActor
enum MomentsVideoProcessor {
    /// 将已选片段导出为不超过 60 秒的 MP4，并生成 JPEG 封面。
    ///
    /// - Parameters:
    ///   - source: 系统编辑器选段或其他有效视频的本地 URL。
    ///   - output: 调用方提供的导出文件路径，导出失败后也由调用方清理。
    ///   - poster: 调用方提供的封面文件路径。
    ///   - progress: 主线程进度回调；导出期间可多次调用，完成封面写入后再次报告 1。
    /// - Returns: 实际导出时长（毫秒）及应用方向变换后的宽高（像素）。
    /// - Throws: 输入不合法、导出或写入错误，以及任务取消。
    static func export(_ source: URL, to output: URL, poster: URL, progress: @escaping @MainActor (Float) -> Void) async throws -> (duration: Int64, width: Int32, height: Int32) {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 60.001,
              let track = try await asset.loadTracks(withMediaType: .video).first else { throw APIClientError.invalidRequest }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = size.applying(transform)
        // 仅拷贝视频和音轨，排除源文件中的位置等元数据轨道。
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: min(duration, CMTime(seconds: 60, preferredTimescale: 600)))
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw APIClientError.invalidRequest }
        try picture.insertTimeRange(range, of: track, at: .zero); picture.preferredTransform = transform
        if let audio = try await asset.loadTracks(withMediaType: .audio).first,
           let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange).intersection(range)
            if audioRange.duration > .zero { try sound.insertTimeRange(audioRange, of: audio, at: audioRange.start) }
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else { throw APIClientError.invalidRequest }
        exporter.outputURL = output; exporter.outputFileType = .mp4
        exporter.metadata = []; exporter.shouldOptimizeForNetworkUse = true
        // 严格截在 60 秒内，避免帧／音轨尾部舍入导致服务端拒绝。
        exporter.timeRange = CMTimeRange(start: .zero, duration: min(duration, CMTime(seconds: 60, preferredTimescale: 600)))
        // 取消监控任务同时请求 AVFoundation 停止导出，仍等待其完成回调后返回。
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(exporter.progress)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if exporter.status == .exporting || exporter.status == .waiting { exporter.cancelExport() }
        }
        defer { monitor.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { monitor.cancel() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw exporter.error ?? APIClientError.invalidRequest }
        let result = AVURLAsset(url: output)
        let actual = try await result.load(.duration)
        let milliseconds = Int64((actual.seconds * 1000).rounded())
        guard milliseconds > 0, milliseconds <= 60_000 else { throw APIClientError.invalidRequest }
        let generator = AVAssetImageGenerator(asset: result); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, any Error>) in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? APIClientError.invalidRequest) }
            }
        }
        try Task.checkCancellation()
        guard let bytes = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw APIClientError.invalidRequest }
        try bytes.write(to: poster, options: .atomic)
        progress(1)
        guard let rendered = try await result.loadTracks(withMediaType: .video).first else { throw APIClientError.invalidRequest }
        let renderedSize = try await rendered.load(.naturalSize), renderedTransform = try await rendered.load(.preferredTransform)
        let display = renderedSize.applying(renderedTransform)
        let width = abs(display.width), height = abs(display.height)
        guard width > 0, height > 0, max(width, height) <= 1920, min(width, height) <= 1080,
              width <= abs(oriented.width) + 1, height <= abs(oriented.height) + 1 else { throw APIClientError.invalidRequest }
        return (milliseconds, Int32(width), Int32(height))
    }
}
