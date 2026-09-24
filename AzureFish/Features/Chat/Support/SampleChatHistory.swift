import AppLocalization
import AVFAudio
import Foundation
import OSLog

/// 聊天历史的临时样例来源；资源准备不经过发送、回复或系统授权流程。
@available(iOS 16.0, *)
@MainActor
enum SampleChatHistory {
    private static let logger = Logger(subsystem: "AzureFish.Chat", category: "SampleChatHistory")

    /// 判断正常入口是否应加载完整样例；专用调试场景只加载各自指定的数据。
    static func isEnabled(arguments: [String]) -> Bool {
        !arguments.contains { argument in
            argument == "-imessage-menu-fixture" || argument == "-imessage-save-fixture" || argument == "preview-video"
                || argument == "-media-benchmark" || argument == "-imessage-basic-history"
        }
    }

    /// 按进入页面时的语言准备普通文本、富文本与附件的收发样例；单项失败跳过，取消则回收本批全部文件。
    static func load(
        store: any AttachmentStoring,
        localizer: Localizer = .live,
        resourceDirectory: URL? = Bundle.main.url(forResource: "AttachmentPreviewResources", withExtension: "bundle")
    ) async throws -> [MessageHistoryEntry] {
        // 在首次挂起前解析文案，避免导入期间切换语言产生混合文案。
        let richText = MessageText(runs: [
            .init(localizer.text("imessage.seed.rich.bold"), style: .bold),
            .init(" · "),
            .init(localizer.text("imessage.seed.rich.italic"), style: .italic),
            .init("\n"),
            .init(localizer.text("imessage.seed.rich.underline"), style: .underline),
            .init(" · "),
            .init(localizer.text("imessage.seed.rich.strikethrough"), style: .strikethrough),
            .init("\n"),
            .init(localizer.text("imessage.seed.rich.mixed"), style: [.bold, .italic, .underline]),
        ])
        let linkTitle = localizer.text("imessage.seed.link.title")
        var samples = ["plain", "phone", "address", "url", "email", "date", "flight",
                       "shipment", "money", "physicalValue", "mixed"].flatMap { name in
            pair(.userText(localizer.text("imessage.seed.text.\(name)")))
        }
        samples += pair(.richText(richText))
        var created: [URL] = []
        var completed = false
        defer {
            if !completed { created.forEach { store.removeFile(at: $0) } }
        }

        for name in ["preview-image-03.jpg", "preview-image-01.gif", "live-photo.jpg",
                     "preview-video-01.mp4", "default-message.caf", "preview-document-01.pdf"] {
            try Task.checkCancellation()
            let start = created.count
            do {
                guard let resourceDirectory else { throw CocoaError(.fileNoSuchFile) }
                let original = try store.importFile(at: resourceDirectory.appendingPathComponent(name),
                                                    prefix: "sample-message", pathExtension: nil)
                created.append(original)
                let attachment: Attachment
                switch name {
                case "default-message.caf":
                    let metadata = try await audioMetadata(at: original)
                    // 转写忠实对应随包中文录音；它不是随界面语言变化的翻译。
                    attachment = .audio(.init(fileURL: original, duration: metadata.duration,
                        waveform: metadata.waveform, transcript: "你好，这是一条语音消息。点击播放，听听效果。"))
                case "preview-document-01.pdf":
                    let bytes = try original.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    attachment = .file(.init(id: UUID(), fileURL: original, displayName: "Claude.pdf",
                        typeIdentifier: "com.adobe.pdf", byteCount: Int64(bytes)))
                default:
                    let thumbnail = store.makeFileURL(prefix: "sample-cover", pathExtension: "jpg")
                    created.append(thumbnail)
                    let metadata = try await MediaImportProcessor.makeMetadata(originalURL: original,
                        thumbnailURL: thumbnail, isVideo: name.hasSuffix(".mp4"))
                    try Task.checkCancellation()
                    var pairedVideo: URL?
                    if name == "live-photo.jpg" {
                        pairedVideo = try store.importFile(at: resourceDirectory.appendingPathComponent("live-photo.mov"),
                                                          prefix: "sample-live", pathExtension: nil)
                        created.append(pairedVideo!)
                    }
                    attachment = .mediaGroup(.init(items: [.init(assetIdentifier: nil,
                        originalFileURL: original, thumbnailFileURL: thumbnail, pixelSize: metadata.pixelSize,
                        kind: metadata.kind, isAnimatedImage: metadata.isAnimatedImage, livePhotoVideoURL: pairedVideo)]))
                }
                try Task.checkCancellation()
                samples += pair(.attachment(attachment))
            } catch {
                let partial = Array(created[start...])
                partial.forEach { store.removeFile(at: $0) }
                created.removeSubrange(start...)
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if ChatDiagnostics.isEnabled {
                    logger.error("[SampleChatHistory] \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        samples += pair(.attachment(.link(.init(url: URL(string: "https://www.apple.com")!, title: linkTitle))))
        try Task.checkCancellation()
        for sample in samples {
            if case .attachment(let attachment) = sample.content { store.registerCommitted(attachment) }
        }
        completed = true
        return samples
    }

    /// 两个方向共享只读文件，但使用独立附件和媒体项目身份。
    private static func pair(_ content: MessageContent) -> [MessageHistoryEntry] {
        let outgoing: MessageContent
        if case .attachment(let attachment) = content { outgoing = .attachment(attachment.simulatedReply()) }
        else { outgoing = content }
        return [.init(direction: .incoming, content: content), .init(direction: .outgoing, content: outgoing)]
    }

    /// 离开主 Actor 读取随包短音频，直接从 PCM 获取真实时长和振幅。
    @concurrent private static func audioMetadata(at url: URL) async throws -> (duration: TimeInterval, waveform: [Float]) {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var waveform: [Float] = []
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
            }
            waveform.append(min(1, max(0.08, sqrt(peak))))
        }
        return (Double(file.length) / file.processingFormat.sampleRate, waveform)
    }
}
