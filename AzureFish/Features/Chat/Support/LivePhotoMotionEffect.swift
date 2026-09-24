import AVFoundation
import CoreImage
import UIKit

/// 选择属于单次预览，不改写照片、配对视频或保存快照。
enum LivePhotoPlaybackMode: CaseIterable {
    case live, loop, bounce, off

    var isContinuous: Bool { self == .loop || self == .bounce }
    var titleKey: String {
        switch self {
        case .live: "imessage.preview.live.on"
        case .loop: "imessage.preview.live.loop"
        case .bounce: "imessage.preview.live.bounce"
        case .off: "imessage.preview.live.off"
        }
    }
    var symbol: String {
        switch self {
        case .live: "livephoto"
        case .loop: "repeat"
        case .bounce: "arrow.left.and.right"
        case .off: "livephoto.slash"
        }
    }
}

/// 配对视频的有界帧序列。倒序直接引用同一批帧，不依赖编码器是否支持负速率播放。
struct LivePhotoMotionFrames: Sendable {
    let images: [CGImage]
    let duration: TimeInterval

    func index(at elapsed: TimeInterval, mode: LivePhotoPlaybackMode) -> Int {
        guard images.count > 1 else { return 0 }
        let step = Int(max(0, elapsed) / (duration / Double(images.count)))
        if mode == .bounce {
            let last = images.count - 1
            let phase = step % (2 * last)
            return phase <= last ? phase : 2 * last - phase
        }
        return step % images.count
    }

    @concurrent
    nonisolated static func load(video: URL, targetSize: CGSize) async throws -> Self {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let range = try await track.load(.timeRange)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // 视频轨道使用左上角坐标，Core Image 使用左下角坐标。
        // 先转换线性部分；平移在下方按实际图像 extent 归零。
        let imageTransform = CGAffineTransform(a: transform.a, b: -transform.b,
            c: -transform.c, d: transform.d, tx: 0, ty: 0)
        let transformed = naturalSize.applying(transform)
        let width = max(1, abs(transformed.width)), height = max(1, abs(transformed.height))
        let count = max(2, min(180, Int(ceil(min(duration, 30) * 24))))
        // 当前页最多约 48 MB 解码像素；长片段降低采样率，保留完整时间范围。
        let pixelBudget = 12_000_000.0 / Double(count)
        let scale = min(1, sqrt(pixelBudget / (width * height)),
                        max(1, targetSize.width) / width, max(1, targetSize.height) / height)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        defer { reader.cancelReading() }
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bounds = CGRect(x: 0, y: 0, width: max(1, floor(width * scale)), height: max(1, floor(height * scale)))
        var images: [CGImage] = []
        // 顺序解码只经过一次 GOP；避免对真实 HEVC 配对视频密集随机寻帧。
        while reader.status == .reading {
            try Task.checkCancellation()
            let hasSample = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds - range.start.seconds
                guard images.count < count, seconds >= Double(images.count) * duration / Double(count),
                      let pixels = CMSampleBufferGetImageBuffer(sample) else { return true }
                var image = CIImage(cvPixelBuffer: pixels).transformed(by: imageTransform)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let rendered = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                repeat { images.append(rendered) }
                while images.count < count && seconds >= Double(images.count) * duration / Double(count)
                return true
            }
            if !hasSample { break }
        }
        try Task.checkCancellation()
        guard reader.status != .failed, let last = images.last else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        // 最后一帧覆盖其剩余显示时长，包括非整数帧率的视频尾部。
        while images.count < count { images.append(last) }
        return Self(images: images, duration: duration)
    }
}

/// 显示链路只推进时间与替换像素，保持外层照片的缩放和转场几何。
@MainActor
final class LivePhotoMotionEffect: NSObject {
    let view = UIImageView()
    private var frames: LivePhotoMotionFrames?
    private var mode: LivePhotoPlaybackMode = .loop
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private(set) var displayedFrameIndex = 0

    @MainActor
    private final class TickTarget: NSObject {
        weak var owner: LivePhotoMotionEffect?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    override init() {
        super.init()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.isHidden = true
        view.isUserInteractionEnabled = false
    }

    func start(frames: LivePhotoMotionFrames, mode: LivePhotoPlaybackMode) {
        stop()
        self.frames = frames
        self.mode = mode
        startTime = CACurrentMediaTime()
        view.isHidden = false
        view.image = UIImage(cgImage: frames.images[0])
        let target = TickTarget()
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 24)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func tick(_ link: CADisplayLink) {
        guard let frames else { return }
        let index = frames.index(at: link.timestamp - startTime, mode: mode)
        guard index != displayedFrameIndex else { return }
        displayedFrameIndex = index
        view.image = UIImage(cgImage: frames.images[index])
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        frames = nil
        displayedFrameIndex = 0
        view.image = nil
        view.isHidden = true
    }

    isolated deinit { displayLink?.invalidate() }
}
