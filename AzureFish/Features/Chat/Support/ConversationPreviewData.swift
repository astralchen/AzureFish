//
//  ConversationPreviewData.swift
//  Demo
//

#if DEBUG
import Foundation
import UIKit

/// 供组件预览使用的固定消息、草稿与本地化示例值。
@available(iOS 16.0, *)
@MainActor
enum ConversationPreviewData {

    /// 统一预览使用现有固定媒体资源，不创建临时业务身份。
    static var attachmentPreviewItems: [AttachmentPreviewItem] {
        AttachmentPreviewItem.prepare(pastedMediaDrafts[0].attachment)
    }

    /// 音频气泡和录音预览共用的固定归一化波形采样。
    static let audioWaveform: [Float] = [
        0.18, 0.24, 0.34, 0.45, 0.72, 0.48, 0.38, 0.84, 0.62,
        0.42, 0.28, 0.56, 0.78, 0.52, 0.36, 0.22, 0.18, 0.12,
        0.16, 0.22, 0.30, 0.52, 0.88, 0.64, 0.42, 0.76, 0.58,
        0.38, 0.26, 0.48, 0.70, 0.46, 0.32, 0.20, 0.16, 0.10,
    ]

    /// 与真实录音状态使用相同固定槽位规则的确定性波形。
    static let recordingWaveform = RecordingWaveform
        .displaySamples(audioWaveform + Array(audioWaveform.reversed()))

    /// 用于音频草稿布局预览的固定附件值；文件路径不保证可播放。
    static let audioAttachment = AudioAttachment(
        id: UUID(uuidString: "3B8B4C03-3AEF-4126-B6D9-B073905955F4")!,
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-preview.m4a"),
        duration: 3,
        waveform: audioWaveform
    )

    /// 以本地示例图片构造的粘贴媒体草稿集合。
    static let pastedMediaDrafts: [DocumentDraft] = {
        let thumbnail = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-paste-preview.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 80, width: 160, height: 40))
            UIColor.systemYellow.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 106, y: 14, width: 28, height: 28))
        }
        try? image.pngData()?.write(to: thumbnail, options: .atomic)
        return [MediaKind.image, .video(duration: 12)].enumerated().map { index, kind in
            let id = UUID(uuidString: index == 0 ? "F0CBF955-17EA-4AF3-8713-A099113A3034" : "F0CBF955-17EA-4AF3-8713-A099113A3035")!
            return .init(attachment: .mediaGroup(.init(id: id, items: [.init(
                id: id, assetIdentifier: nil, originalFileURL: thumbnail, thumbnailFileURL: thumbnail,
                pixelSize: CGSize(width: 160, height: 120), kind: kind
            )])))
        }
    }()

    /// 用于文档卡片和输入栏布局预览的示例文件与链接草稿。
    static let documentDrafts: [DocumentDraft] = [
        .init(attachment: .file(.init(
            id: UUID(uuidString: "F0CBF955-17EA-4AF3-8713-A099113A3031")!,
            fileURL: URL(fileURLWithPath: "/preview/Audio Message.m4a"),
            displayName: "Audio Message.m4a", typeIdentifier: "public.mpeg-4-audio", byteCount: 10_240
        ))),
        .init(attachment: .file(.init(
            id: UUID(uuidString: "F0CBF955-17EA-4AF3-8713-A099113A3032")!,
            fileURL: URL(fileURLWithPath: "/preview/Example.json"),
            displayName: "Example.json", typeIdentifier: "public.json", byteCount: 2_048
        ))),
        .init(attachment: .link(.init(
            id: UUID(uuidString: "F0CBF955-17EA-4AF3-8713-A099113A3033")!,
            url: URL(string: "https://developer.apple.com")!, title: "Apple Developer"
        ))),
    ]

    /// 收到的音频气泡使用的示例附件及转写文本。
    static let incomingAudioAttachment = AudioAttachment(
        id: UUID(uuidString: "71FA16C1-CFC2-49DB-979A-8F7188D0E768")!,
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-incoming-preview.m4a"),
        duration: 3,
        waveform: audioWaveform
    )

    /// 发出的音频气泡使用的示例附件及转写文本。
    static let outgoingAudioAttachment = AudioAttachment(
        id: UUID(uuidString: "54BBE51E-6E67-46D0-B665-4441800620D2")!,
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("imessage-outgoing-preview.m4a"),
        duration: 7,
        waveform: Array(audioWaveform.reversed())
    )

    /// 预览时间线使用的固定时间分隔项。
    static let timestamp = TimestampPresentation(
        sourceMessageID: 0,
        text: "19:09"
    )

    /// 用于检查收到文本气泡的固定消息。
    static let incomingMessage = MessagePresentation(
        id: 0,
        direction: .incoming,
        text: "嗨！我们今天还是按原计划见面吗？",
        deliveryText: nil
    )

    /// 用于检查发出文本气泡和已读文字的固定消息。
    static let outgoingMessage = MessagePresentation(
        id: 1,
        direction: .outgoing,
        text: "当然，七点我没问题。",
        deliveryText: "已读"
    )

    /// 用于检查连续收到消息布局的后续示例消息。
    static let followUpMessage = MessagePresentation(
        id: 2,
        direction: .incoming,
        text: "太好了，我会提前几分钟到。",
        deliveryText: nil
    )

    /// 用于检查收到音频气泡的固定消息。
    static let incomingAudioMessage = MessagePresentation(
        id: 3,
        direction: .incoming,
        attachment: .audio(incomingAudioAttachment),
        deliveryText: nil
    )

    /// 用于检查发出音频气泡和已读文字的固定消息。
    static let outgoingAudioMessage = MessagePresentation(
        id: 4,
        direction: .outgoing,
        attachment: .audio(outgoingAudioAttachment),
        deliveryText: "已读"
    )

    /// 输入状态预览使用的辅助功能描述。
    static let typingAccessibilityLabel = "Alex 正在输入"
    /// 联系人导航标题预览使用的副标题。
    static let contactSubtitle = "iMessage"
    /// 文本输入栏预览使用的占位文字。
    static let composerPlaceholder = "iMessage"
    /// 发送按钮预览使用的辅助功能标签。
    static let sendAccessibilityLabel = "发送"
    /// 输入栏各按钮和状态预览使用的文字集合。
    static let composerStrings = ComposerStrings(
        placeholder: composerPlaceholder,
        send: sendAccessibilityLabel,
        addAttachment: "Add attachment",
        audio: "Audio",
        dictate: "Dictate",
        stopDictation: "Stop dictation",
        stopRecording: "Stop recording",
        cancelAudio: "Cancel audio",
        playAudio: "Play audio",
        pauseAudio: "Pause audio",
        recordingRequiresEmptyDraft: "若要录音，请清除输入栏。",
        file: "文件",
        link: "链接",
        mediaPlaceholder: "添加注释或发送"
    )
    /// 用于检查多行文本输入高度的示例草稿。
    static let composerMultilineText = "今晚七点见\n我会提前几分钟到"
    /// 用于检查从右向左文本布局的阿拉伯语草稿。
    static let composerRTLText = "مساء الخير\nسأصل في السابعة"
    /// 预览和可重复场景使用的固定日期。
    static let fixedDate = Date(timeIntervalSince1970: 1_788_257_740)

    /// 包含时间、文本消息和输入状态的完整预览时间线快照。
    static let state = ChatViewModel.State(
        timeline: [
            TimelineItem(
                id: .timestamp(sourceMessageID: timestamp.sourceMessageID),
                content: .timestamp(timestamp)
            ),
            TimelineItem(
                id: .message(incomingMessage.id),
                content: .message(incomingMessage)
            ),
            TimelineItem(
                id: .message(outgoingMessage.id),
                content: .message(outgoingMessage)
            ),
            TimelineItem(
                id: .message(followUpMessage.id),
                content: .message(followUpMessage)
            ),
            TimelineItem(
                id: .message(incomingAudioMessage.id),
                content: .message(incomingAudioMessage)
            ),
            TimelineItem(
                id: .message(outgoingAudioMessage.id),
                content: .message(outgoingAudioMessage)
            ),
            TimelineItem(
                id: .typing,
                content: .typing(
                    accessibilityLabel: typingAccessibilityLabel
                )
            ),
        ],
        isTyping: true
    )
}
#endif
