#if DEBUG
import AVFoundation
import UIKit

/// UI 回归通过启动参数使用真实本地附件；正常启动不改变会话内容。
@available(iOS 16.0, *)
@MainActor
enum AttachmentSavePreviewFixtures {
    /// 从随包资源创建页面独立副本；逐项导入，取消或失败时删除部分产物。
    ///
    /// `resources` 使用全部 20 张图片，`resources-video` 使用 6 段视频，
    /// `resources-pdf` 使用 PDF，`resources-heic` 使用新增 HEIC 静态原件。
    /// `resources-draft` 混合真实视频和图片，并模拟动态图片角标；不代表实况资源导入或播放验证。
    /// Bundle 原件永远不登记到页面清理目录；每组仍遵守 20 项上限。
    @available(iOS 17.0, *)
    static func resourceAttachment(named name: String, store: any AttachmentStoring) async throws -> Attachment {
        let kind: String
        switch name {
        case "resources": kind = "image"
        case "resources-heic": kind = "image"
        case "resources-video": kind = "video"
        case "resources-pdf": kind = "document"
        case "resources-draft", "resources-live", "resources-live-single", "resources-live-audio": kind = "mixed"
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let directory = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let sources: [URL]
        if name == "resources-live-single" || name == "resources-live-audio" {
            sources = [directory.appendingPathComponent("live-photo.jpg")]
        } else if name == "resources-live" {
            sources = ["live-photo.jpg", "preview-image-02.png", "preview-image-01.gif", "live-photo.jpg"]
                .map { directory.appendingPathComponent($0) }
        } else if name == "resources-draft" {
            sources = ["preview-video-01.mp4", "preview-image-08.png", "preview-image-09.png"]
                .map { directory.appendingPathComponent($0) }
        } else {
            sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("preview-\(kind)-") }
                .filter { name == "resources-heic" ? $0.pathExtension == "heic" : $0.pathExtension != "heic" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !sources.isEmpty, sources.count <= MediaGroupAttachment.selectionLimit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var created: [URL] = []
        var committed = false
        defer {
            if !committed { created.forEach { store.removeFile(at: $0) } }
        }
        var items: [MediaItem] = []
        for source in sources {
            try Task.checkCancellation()
            let original = try store.importFile(at: source, prefix: "bundled-preview", pathExtension: nil)
            created.append(original)
            if kind == "document" {
                let bytes = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let attachment = Attachment.file(.init(id: UUID(), fileURL: original, displayName: "Claude.pdf",
                    typeIdentifier: "com.adobe.pdf", byteCount: Int64(bytes)))
                store.registerCommitted(attachment)
                committed = true
                return attachment
            }
            let thumbnail = store.makeFileURL(prefix: "bundled-preview-cover", pathExtension: "jpg")
            created.append(thumbnail)
            let metadata = try await MediaImportProcessor.makeMetadata(originalURL: original,
                thumbnailURL: thumbnail,
                isVideo: kind == "video" || source.lastPathComponent.hasPrefix("preview-video-"))
            try Task.checkCancellation()
            let pairedVideo: URL?
            if ["resources-live", "resources-live-single", "resources-live-audio"].contains(name), source.lastPathComponent == "live-photo.jpg" {
                pairedVideo = try store.importFile(at: directory.appendingPathComponent("live-photo.mov"), prefix: "live-video", pathExtension: nil)
                created.append(pairedVideo!)
                if name == "resources-live-audio", let pairedVideo {
                    let output = store.makeFileURL(prefix: "audible-live", pathExtension: "mov")
                    created.append(output)
                    try await addLivePhotoAudio(video: pairedVideo, audio: directory.appendingPathComponent("default-message.caf"), output: output)
                    try FileManager.default.removeItem(at: pairedVideo)
                    try FileManager.default.moveItem(at: output, to: pairedVideo)
                }
            } else { pairedVideo = nil }
            items.append(.init(assetIdentifier: nil, originalFileURL: original,
                thumbnailFileURL: thumbnail, pixelSize: metadata.pixelSize, kind: metadata.kind,
                isAnimatedImage: metadata.isAnimatedImage || (name == "resources-draft" && !metadata.kind.isVideo),
                livePhotoVideoURL: pairedVideo))
        }
        let attachment = Attachment.mediaGroup(.init(items: items))
        store.registerCommitted(attachment)
        committed = true
        return attachment
    }

    /// 原始实况示例没有音轨；验收样例保留照片标识和 timed metadata，加入随包语音的前三秒。
    @available(iOS 17.0, *)
    private static func addLivePhotoAudio(video: URL, audio: URL, output: URL) async throws {
        let asset = AVURLAsset(url: video)
        let voice = AVURLAsset(url: audio)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for track in try await asset.load(.tracks) {
            guard let destination = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let range = try await track.load(.timeRange)
            try destination.insertTimeRange(range, of: track, at: range.start)
            destination.preferredTransform = try await track.load(.preferredTransform)
        }
        guard let voiceTrack = try await voice.loadTracks(withMediaType: .audio).first,
              let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
              let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let voiceDuration = try await voice.load(.duration)
        try destination.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, voiceDuration)), of: voiceTrack, at: .zero)
        exporter.metadata = try await asset.load(.metadata)
        exporter.outputURL = output
        exporter.outputFileType = .mov
        await exporter.export()
        guard exporter.status == .completed else { throw exporter.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// 为页内播放 UI 测试生成固定十秒视频，不读取相册或网络。
    static func videoAttachment(store: any AttachmentStoring, transform: CGAffineTransform = .identity) async throws -> Attachment {
        let url = store.makeFileURL(prefix: "preview-video", pathExtension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        let error = NSError(domain: "PreviewFixture", code: 1)
        writer.add(input)
        guard writer.startWriting() else { throw error }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let pixels = buffer else { throw error }
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x7f, CVPixelBufferGetBytesPerRow(pixels) * 240)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard input.isReadyForMoreMediaData, adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame * 5), timescale: 1)) else { throw error }
        }
        writer.endSession(atSourceTime: CMTime(seconds: 10, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw error }
        let thumbnail = store.makeFileURL(prefix: "preview-video-cover", pathExtension: "png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        try image.pngData()?.write(to: thumbnail)
        let displayed = image.size.applying(transform)
        let attachment = Attachment.mediaGroup(.init(items: [.init(assetIdentifier: nil, originalFileURL: url, thumbnailFileURL: thumbnail,
            pixelSize: CGSize(width: abs(displayed.width), height: abs(displayed.height)), kind: .video(duration: 10))]))
        store.registerCommitted(attachment)
        return attachment
    }

    /// 根据调试启动参数创建真实本地保存样例，并登记为已提交附件。
    ///
    /// 未指定支持的样例类型时返回 `nil`；文件生成失败时抛出错误。
    static func attachment(store: any AttachmentStoring) throws -> Attachment? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-imessage-save-fixture"), arguments.indices.contains(index + 1) else { return nil }
        let attachment: Attachment
        switch arguments[index + 1] {
        case "stack2", "stack5", "stack20":
            let count = Int(arguments[index + 1].dropFirst(5)) ?? 5
            let colors: [UIColor] = [.systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemPink]
            let items = try (0..<count).map { index in
                let url = store.makeFileURL(prefix: "stack-preview-\(index)", pathExtension: "png")
                let image = UIGraphicsImageRenderer(size: CGSize(width: 432, height: 600)).image { context in
                    colors[index % colors.count].setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 432, height: 600))
                    UIColor.white.withAlphaComponent(0.15).setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 170, y: 40, width: 300, height: 300))
                    ("\(index + 1)" as NSString).draw(at: CGPoint(x: 35, y: 35), withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 100), .foregroundColor: UIColor.white
                    ])
                    ("MEDIA STACK" as NSString).draw(at: CGPoint(x: 35, y: 500), withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 32), .foregroundColor: UIColor.white
                    ])
                }
                try image.pngData()?.write(to: url)
                return MediaItem(assetIdentifier: nil, originalFileURL: url,
                                            thumbnailFileURL: url, pixelSize: image.size, kind: .image)
            }
            attachment = .mediaGroup(.init(items: items))
        case "photo", "group":
            let url = store.makeFileURL(prefix: "save-preview", pathExtension: "png")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
                UIColor.systemYellow.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 210, y: 24, width: 48, height: 48))
                UIColor.systemGreen.setFill()
                context.fill(CGRect(x: 0, y: 140, width: 300, height: 60))
            }
            try image.pngData()?.write(to: url)
            let count = arguments[index + 1] == "group" ? 3 : 1
            attachment = .mediaGroup(.init(items: (0..<count).map { _ in
                .init(assetIdentifier: nil, originalFileURL: url, thumbnailFileURL: url,
                      pixelSize: image.size, kind: .image)
            }))
        case "audio", "audio-message":
            let url = store.makeFileURL(prefix: "save-preview", pathExtension: "caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            if let channel = buffer.floatChannelData?[0] { channel.initialize(repeating: 0, count: 16_000) }
            let audio = try AVAudioFile(forWriting: url, settings: format.settings)
            try audio.write(from: buffer)
            if arguments[index + 1] == "audio-message" {
                // 转写样例让回归同时覆盖气泡、波形与正文的收起；未指定参数时仍保留无转写样例。
                let transcript = arguments.contains("-imessage-menu-audio-transcript")
                    ? "你好，这是一条语音消息。点击播放，听听效果。" : nil
                attachment = .audio(.init(fileURL: url, duration: 1,
                    waveform: [0.2, 0.6, 0.8, 0.4, 0.3], transcript: transcript))
            } else {
                attachment = .file(.init(id: UUID(), fileURL: url, displayName: "Audio Message.caf",
                    typeIdentifier: "com.apple.coreaudio-format", byteCount: 64_000))
            }
        case "preview-image-file", "preview-gif-file":
            let isGIF = arguments[index + 1] == "preview-gif-file"
            guard let directory = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle") else {
                throw CocoaError(.fileNoSuchFile)
            }
            let source = directory.appendingPathComponent(isGIF ? "preview-image-01.gif" : "live-photo.jpg")
            let url = try store.importFile(at: source, prefix: "preview-file", pathExtension: nil)
            attachment = .file(.init(id: UUID(), fileURL: url, displayName: source.lastPathComponent,
                typeIdentifier: isGIF ? "com.compuserve.gif" : "public.jpeg", byteCount: 0))
        case "preview-rtf":
            let url = store.makeFileURL(prefix: "preview-system", pathExtension: "rtf")
            let data = Data("{\\rtf1\\ansi Quick Look compatibility preview.}".utf8)
            try data.write(to: url)
            attachment = .file(.init(id: UUID(), fileURL: url, displayName: "Compatibility.rtf", typeIdentifier: "public.rtf", byteCount: Int64(data.count)))
        case "preview-unavailable":
            let url = store.makeFileURL(prefix: "missing", pathExtension: "pdf")
            attachment = .file(.init(id: UUID(), fileURL: url, displayName: "Unavailable.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 0))
        case "preview-text":
            let url = store.makeFileURL(prefix: "preview-text", pathExtension: "txt")
            let text = String(repeating: "附件预览 · Liquid Glass\nReadable text with selection.\n\n", count: 50)
            try Data(text.utf8).write(to: url)
            attachment = .file(.init(id: UUID(), fileURL: url, displayName: "Read me.txt", typeIdentifier: "public.plain-text", byteCount: Int64(text.utf8.count)))
        case "document":
            let url = store.makeFileURL(prefix: "save-preview", pathExtension: "pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200)).writePDF(to: url) { context in
                context.beginPage()
                ("Attachment save preview" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: nil)
            }
            attachment = .file(.init(id: UUID(), fileURL: url, displayName: "Attachment.pdf",
                typeIdentifier: "com.adobe.pdf", byteCount: 1000))
        default: return nil
        }
        store.registerCommitted(attachment)
        return attachment
    }
}
#endif
