import Foundation
import MediaWorkerSupport
import AVFoundation
import ImageIO
import Photos
import UniformTypeIdentifiers

/// macOS 原生解码边界；工作进程只访问本次任务的文件，主进程负责超时终止。
enum NativeMediaProcessor {
    enum Failure: Error { case invalid }
    static func process(_ job: WorkerJob) async throws -> WorkerResult {
        switch job.kind {
        case "image", "live_photo":
            var result = try image(URL(fileURLWithPath: job.original), output: job.outputDirectory)
            if job.kind == "live_photo" {
                guard let paired = job.pairedVideo else { throw Failure.invalid }
                let videoResult = try await video(URL(fileURLWithPath: paired), output: nil)
                result.pairedMime = videoResult.mime
                try await validateLivePhoto([URL(fileURLWithPath: job.original), URL(fileURLWithPath: paired)])
            }
            return result
        case "video": return try await video(URL(fileURLWithPath: job.original), output: job.outputDirectory)
        case "audio": return try await audio(URL(fileURLWithPath: job.original))
        default: throw Failure.invalid
        }
    }
    static func image(_ url: URL, output: String) throws -> WorkerResult {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let type = CGImageSourceGetType(source), let uti = UTType(type as String),
                  let mime = uti.preferredMIMEType,
                  ["image/jpeg", "image/png", "image/heic", "image/heif", "image/gif", "image/webp", "image/tiff"].contains(mime),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw Failure.invalid }
            let width = w.int64Value, height = h.int64Value
            guard width > 0, height > 0, width <= 100_000, height <= 100_000, width * height <= 100_000_000,
                  CGImageSourceGetCount(source) <= 10_000 else { throw Failure.invalid }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1280]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.invalid }
            try jpeg(thumbnail, directory: output)
            var result = WorkerResult(); result.mime = mime; result.width = Int(width); result.height = Int(height)
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if orientation >= 5 { swap(&result.width, &result.height) }
            result.animated = CGImageSourceGetCount(source) > 1; result.preview = "preview.jpg"
            return result
        }
    }
    static func video(_ url: URL, output: String?) async throws -> WorkerResult {
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent), let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.invalid }
        let duration = try await asset.load(.duration).seconds
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let pixels = CGRect(origin: .zero, size: size).applying(transform).standardized.size
        guard duration.isFinite, duration > 0, duration < Double(Int64.max / 1000),
              pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0,
              pixels.width <= 16384, pixels.height <= 16384 else { throw Failure.invalid }
        if let output {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1280, height: 1280)
            let image = try await generator.image(at: CMTime(seconds: min(0.1, duration / 2), preferredTimescale: 600)).image
            try jpeg(image, directory: output)
        }
        var result = WorkerResult(); result.width = Int(pixels.width); result.height = Int(pixels.height)
        result.durationMS = Int64((duration * 1000).rounded()); result.mime = try containerMIME(url, audio: false)
        result.preview = output == nil ? nil : "preview.jpg"; return result
    }
    static func audio(_ url: URL) async throws -> WorkerResult {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .video).isEmpty,
              try await !asset.load(.hasProtectedContent) else { throw Failure.invalid }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let duration = Double(file.length) / format.sampleRate
        guard duration.isFinite, duration >= 1, duration <= 120, format.channelCount > 0, format.channelCount <= 8,
              format.sampleRate > 0, format.sampleRate <= 192000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw Failure.invalid }
        var peaks = [Float](repeating: 0, count: 60)
        while file.framePosition < file.length {
            let start = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw Failure.invalid }
            for index in 0..<Int(buffer.frameLength) {
                let bucket = min(59, Int((start + Int64(index)) * 60 / max(1, file.length)))
                for channel in 0..<Int(format.channelCount) {
                    let value = abs(channels[channel][index])
                    guard value.isFinite else { throw Failure.invalid }
                    peaks[bucket] = max(peaks[bucket], min(1, value))
                }
            }
        }
        let peak = max(peaks.max() ?? 0, 0.0001)
        var result = WorkerResult(); result.mime = try containerMIME(url, audio: true)
        result.durationMS = Int64((duration * 1000).rounded()); result.waveform = peaks.map { $0 / peak }; return result
    }
    // 仅接受实际容器签名；用户文件扩展名和声明 MIME 不决定可接受类型。
    static func containerMIME(_ url: URL, audio: Bool) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let bytes = try file.read(upToCount: 64) ?? Data()
        if bytes.count >= 12, String(data: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let quickTime = String(data: bytes[8..<12], encoding: .ascii) == "qt  "
            guard !audio || !quickTime else { throw Failure.invalid }
            return audio ? "audio/mp4" : (quickTime ? "video/quicktime" : "video/mp4")
        }
        if !audio && bytes.count >= 8 && ["moov", "mdat", "wide"].contains(String(data: bytes[4..<8], encoding: .ascii) ?? "") { return "video/quicktime" }
        if audio && bytes.starts(with: Data("caff".utf8)) { return "audio/x-caf" }
        if audio && bytes.count >= 12 && bytes.starts(with: Data("RIFF".utf8)) && String(data: bytes[8..<12], encoding: .ascii) == "WAVE" { return "audio/wav" }
        throw Failure.invalid
    }
    static func jpeg(_ image: CGImage, directory: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("preview.jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalid }
    }
    @MainActor static func validateLivePhoto(_ urls: [URL]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // 系统可多次回调；只使用完整结果，placeholder 不证明配对成功。
            let completion = LivePhotoCompletion(continuation)
            PHLivePhoto.request(withResourceFileURLs: urls, placeholderImage: nil, targetSize: CGSize(width: 256, height: 256), contentMode: .aspectFit) { photo, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                completion.finish(photo != nil && info[PHLivePhotoInfoErrorKey] == nil && (info[PHLivePhotoInfoCancelledKey] as? Bool) != true)
            }
        }
    }
}
private final class LivePhotoCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    init(_ value: CheckedContinuation<Void, any Error>) { continuation = value }
    func finish(_ success: Bool) {
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        if success { value?.resume() } else { value?.resume(throwing: NativeMediaProcessor.Failure.invalid) }
    }
}
