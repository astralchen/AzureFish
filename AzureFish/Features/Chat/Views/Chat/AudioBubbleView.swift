//
//  AudioBubbleView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 显示播放、波形和时长控件的消息气泡。
@available(iOS 17.0, *)
final class AudioBubbleView: QuickLayoutView {

    /// 参考截图的音频蓝色，不受系统版本默认 tintColor 变化影响。
    static let audioBlue = UIColor(red: 65 / 255, green: 142 / 255, blue: 246 / 255, alpha: 1)
    /// 收到的音频气泡在浅色与深色外观下使用的动态填充颜色。
    private static let incomingFill = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.secondarySystemFill.resolvedColor(with: traits)
            : UIColor(red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    }

    /// 用于触发播放操作的按钮。
    let playButton = UIButton(type: .system)
    /// 显示附件波形和播放进度的绘制视图。
    let waveformView = WaveformView()
    /// 显示音频或视频时长的标签。
    let durationLabel = UILabel()
    /// 显示完整音频转写文本的多行标签。
    let transcriptLabel = UILabel()
    /// 组合气泡主体与尾部的遮罩容器视图。
    private let bubbleMask = UIView()
    /// 绘制连续圆角气泡主体的遮罩视图。
    private let bodyMask = UIView()
    /// 使用框架形状视图绘制气泡尾部遮罩。
    private let tailMask = QuickLayoutShapeView(frame: .zero)

    /// 尾部几何与镜像方向；路径由形状视图根据最新边界生成。
    private struct TailShape: QuickLayoutShape {
        let isMirrored: Bool

        func path(in rect: CGRect) -> CGPath {
            guard rect.width > 0, rect.height > 6 else {
                return CGMutablePath()
            }
            let bottom = rect.height - 6
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2, y: bottom - 18))
            path.addCurve(to: CGPoint(x: 8, y: rect.height), controlPoint1: CGPoint(x: 5, y: bottom - 9), controlPoint2: CGPoint(x: 14, y: bottom + 1))
            path.addCurve(to: CGPoint(x: 27, y: bottom), controlPoint1: CGPoint(x: 12, y: bottom + 5), controlPoint2: CGPoint(x: 18, y: bottom))
            path.close()
            if isMirrored {
                path.apply(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
            }
            path.apply(CGAffineTransform(translationX: rect.minX, y: rect.minY))
            return path.cgPath
        }
    }

    /// 用户点击音频播放按钮时调用的闭包。
    var playbackRequested: (() -> Void)?

    /// 当前气泡显示的音频附件；未配置时为 `nil`。
    private var attachment: AudioAttachment?
    /// 当前附件是否包含转写文本。
    private var hasTranscript: Bool {
        attachment?.transcript != nil
    }
    /// 当前消息的接收或发出方向，用于确定气泡外观与语义对齐。
    private var direction: MessageDirection = .incoming

    /// 定义 `AudioBubbleView` 的布局层级、间距和对齐方式。
    override var body: Layout {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                playButton.resizable().frame(width: 44, height: 44)
                waveformView.resizable().frame(maxWidth: .infinity).frame(height: 36)
                durationLabel.fixedSize().padding(.leading, 8)
            }
            if hasTranscript {
                transcriptLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    /// 使用指定初始边框创建 `AudioBubbleView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        mask = bubbleMask
        bodyMask.backgroundColor = .black
        bodyMask.layer.cornerCurve = .continuous
        tailMask.fillColor = .black
        bubbleMask.addSubview(bodyMask)
        bubbleMask.addSubview(tailMask)
        waveformView.fillsAvailableWidth = true

        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "play.fill")
        configuration.contentInsets = .zero
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        configuration.background.cornerRadius = 14
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        playButton.configuration = configuration
        playButton.accessibilityIdentifier = "imessage.audio.play"
        playButton.addTarget(
            self,
            action: #selector(playButtonDidTap),
            for: .touchUpInside
        )

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: AudioBubbleView, _: UITraitCollection) in
            view.updateFonts()
            view.setNeedsQuickLayout()
        }
        transcriptLabel.font = .preferredFont(forTextStyle: .subheadline)
        transcriptLabel.adjustsFontForContentSizeCategory = true
        transcriptLabel.numberOfLines = 0
        transcriptLabel.textAlignment = .natural
        transcriptLabel.accessibilityIdentifier = "imessage.audio.transcript"
        durationLabel.font = .preferredFont(forTextStyle: .subheadline)
        durationLabel.adjustsFontForContentSizeCategory = true
        durationLabel.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
        isAccessibilityElement = false
    }

    /// 不支持从归档创建 `AudioBubbleView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 使用音频附件和播放状态配置气泡。
    ///
    /// - Parameters:
    ///   - attachment: 气泡所表示的附件。
    ///   - direction: 语义化的接收或发出消息方向。
    ///   - playback: 页面级播放状态。
    ///   - playAccessibilityLabel: 本地化的“播放”操作。
    ///   - pauseAccessibilityLabel: 本地化的“暂停”操作。
    func configure(
        attachment: AudioAttachment,
        direction: MessageDirection,
        playback: PlaybackState,
        playAccessibilityLabel: String,
        pauseAccessibilityLabel: String
    ) {
        self.attachment = attachment
        self.direction = direction
        updateFonts()
        transcriptLabel.text = attachment.transcript
        let isCurrent = playback.attachmentID == attachment.id
        let isPlaying = isCurrent && playback.isPlaying
        let progress = isCurrent ? playback.progress : 0
        waveformView.samples = attachment.waveform
        waveformView.progress = progress
        let elapsedText = Self.playbackTimeText(
            duration: attachment.duration, progress: progress, isPlaying: true, paddedMinutes: true
        )
        durationLabel.text = Self.playbackTimeText(
            duration: attachment.duration, progress: progress, isPlaying: isPlaying, paddedMinutes: true
        )
        playButton.configuration?.image = UIImage(
            systemName: isPlaying ? "pause.fill" : "play.fill"
        )
        playButton.accessibilityLabel = isPlaying
            ? pauseAccessibilityLabel
            : playAccessibilityLabel
        let totalText = Self.durationText(attachment.duration, paddedMinutes: true)
        playButton.accessibilityValue = "\(elapsedText) / \(totalText)"

        switch direction {
        case .incoming:
            backgroundColor = Self.incomingFill
            playButton.tintColor = .white
            playButton.configuration?.background.backgroundColor = Self.audioBlue
            transcriptLabel.textColor = .secondaryLabel
            durationLabel.textColor = .secondaryLabel
            waveformView.playedColor = Self.audioBlue.withAlphaComponent(0.6)
            waveformView.unplayedColor = Self.audioBlue
        case .outgoing:
            backgroundColor = Self.audioBlue
            playButton.tintColor = Self.audioBlue
            playButton.configuration?.background.backgroundColor = .white
            transcriptLabel.textColor = UIColor.white.withAlphaComponent(0.82)
            durationLabel.textColor = UIColor.white.withAlphaComponent(0.6)
            waveformView.playedColor = UIColor.white.withAlphaComponent(0.6)
            waveformView.unplayedColor = .white
        }
        accessibilityLabel = "\(playButton.accessibilityLabel ?? ""), \(durationLabel.text ?? "")"
        setNeedsQuickLayout()
    }

    /// 在所属 Cell 复用前移除消息特定状态。
    func reset() {
        attachment = nil
        direction = .incoming
        playbackRequested = nil
        waveformView.samples = []
        waveformView.progress = 0
        durationLabel.text = nil
        transcriptLabel.text = nil
        setNeedsQuickLayout()
        playButton.accessibilityLabel = nil
        playButton.accessibilityValue = nil
        accessibilityLabel = nil
    }

    /// 在视图进入或离开窗口时更新动态字体与布局。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFonts()
        setNeedsQuickLayout()
    }

    /// 根据当前内容大小类别更新动态字体。
    private func updateFonts() {
        transcriptLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        durationLabel.font = .monospacedDigitSystemFont(
            ofSize: transcriptLabel.font.pointSize, weight: .regular
        )
    }

    /// 菜单使用与气泡相同的主体和尾部，避免高亮预览裁掉尾巴。
    var menuPreviewPath: UIBezierPath {
        let body = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 6))
        let path = UIBezierPath(roundedRect: body, cornerRadius: min(24, min(body.width, body.height) / 2))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tail = UIBezierPath(cgPath: TailShape(isMirrored: direction == .outgoing ? !rtl : rtl).path(in: bounds))
        // 镜像会反转绕向；与主体保持同向，使非零填充合并重叠部分。
        path.append(direction == .outgoing ? (rtl ? tail.reversing() : tail) : (rtl ? tail : tail.reversing()))
        return path
    }

    /// 根据当前边界更新 `AudioBubbleView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 6 else { return }
        let width = bounds.width
        let bottom = bounds.height - 6
        let radius: CGFloat = min(24, min(width, bottom) / 2)
        // 主体保留完整的系统连续圆角。尾巴只补充外轮廓，不切入主体；
        // 两层不透明遮罩以 alpha 合并，避免复合路径的绕向造成交叠区域透白。
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bubbleMask.frame = bounds
        bodyMask.frame = CGRect(x: 0, y: 0, width: width, height: bottom)
        bodyMask.layer.cornerRadius = radius
        tailMask.frame = bubbleMask.bounds
        tailMask.setShape(TailShape(isMirrored: direction == .outgoing ? !rtl : rtl))
        tailMask.layoutIfNeeded()
        CATransaction.commit()
    }

    /// 将播放按钮事件转发给播放请求回调。
    @objc private func playButtonDidTap() {
        playbackRequested?()
    }

    /// 返回时钟样式的音频时长文本。
    ///
    /// - Parameter duration: 音频时长，单位为秒。
    /// - Returns: 格式为 `m:ss` 的字符串。
    static func durationText(_ duration: TimeInterval, paddedMinutes: Bool = false) -> String {
        let seconds = max(0, Int(duration.rounded()))
        return String(format: paddedMinutes ? "%02d:%02d" : "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 播放时从零按完整秒递增；暂停保留时间，未播放或停止重置后显示总时长。
    static func playbackTimeText(
        duration: TimeInterval, progress: Double, isPlaying: Bool,
        paddedMinutes: Bool = false
    ) -> String {
        let progress = min(1, max(0, progress))
        let total = max(0, duration.rounded())
        let elapsed = progress >= 1
            ? total
            : (duration * progress).rounded(.down)
        return durationText(isPlaying || progress > 0 ? elapsed : total, paddedMinutes: paddedMinutes)
    }
}

#if DEBUG
/// 创建指定收发方向及可选转写文本的音频气泡预览控制器。
@available(iOS 17.0, *)
@MainActor
private func makeAudioBubblePreview(
    direction: MessageDirection, transcript: String? = nil
) -> UIViewController {
    let source = direction == .outgoing
        ? ConversationPreviewData.outgoingAudioMessage
        : ConversationPreviewData.incomingAudioMessage
    var audio = source.audio!
    audio.transcript = transcript
    let message = MessagePresentation(id: source.id, direction: direction, attachment: .audio(audio), deliveryText: source.deliveryText)
    let cell = AudioBubbleCell(frame: .zero)
    cell.configure(
        message,
        playback: .idle,
        playAccessibilityLabel: "播放音频",
        pauseAccessibilityLabel: "暂停音频"
    )
    return QuickLayoutHostingController {
        cell.resizable(axis: .horizontal).frame(width: 402)
    }
}

@available(iOS 17.0, *)
#Preview("音频消息 · 收到") {
    makeAudioBubblePreview(direction: .incoming)
}

@available(iOS 17.0, *)
#Preview("音频消息 · 发出") {
    makeAudioBubblePreview(direction: .outgoing)
}
@available(iOS 17.0, *)
#Preview("音频文本 · 收到") {
    makeAudioBubblePreview(direction: .incoming, transcript: "你好，你吃饭了吗？")
}
@available(iOS 17.0, *)
#Preview("音频文本 · 发出") {
    makeAudioBubblePreview(direction: .outgoing, transcript: "你好，你吃饭了吗？")
}
@available(iOS 17.0, *)
#Preview("音频长文本 · 收到") {
    makeAudioBubblePreview(direction: .incoming, transcript: "你好，你吃饭了吗？今天下午我们一起去散步吧，到了以后再给我发消息。")
}
@available(iOS 17.0, *)
#Preview("音频长文本 · 发出") {
    makeAudioBubblePreview(direction: .outgoing, transcript: "你好，你吃饭了吗？今天下午我们一起去散步吧，到了以后再给我发消息。")
}
#endif
