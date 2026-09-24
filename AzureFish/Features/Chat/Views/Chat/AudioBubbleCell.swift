//
//  AudioBubbleCell.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 承载音频消息气泡的可复用时间线 Cell。
@available(iOS 17.0, *)
final class AudioBubbleCell: QuickLayoutCollectionViewCell {
    /// 随 Cell 复用重置的菜单辅助功能绑定。
    let messageMenu = MessageMenuAccessibility()


    /// 显示音频波形、时长和转写文本的气泡视图。
    let bubbleView = AudioBubbleView(frame: .zero)
    /// 显示发送进度、失败入口及送达文本的状态视图。
    let deliveryStatusView = DeliveryStatusView()
    /// 状态视图中用于显示本地化送达文本的标签。
    var deliveryLabel: UILabel { deliveryStatusView.label }

    /// 用户请求切换播放时调用的闭包，参数为消息身份与音频附件。
    var playbackRequested: ((Int, AudioAttachment) -> Void)?

    /// 当前绑定的消息展示模型；未配置或复用清理后为 `nil`。
    private var message: MessagePresentation?

    /// 需要随单元格同步更新布局方向的内容视图。
    override var quickLayoutDirectionViews: [UIView] {
        super.quickLayoutDirectionViews + [bubbleView]
    }

    /// 定义 `AudioBubbleCell` 的布局层级、间距和对齐方式。
    @LayoutBuilder
    override var body: Layout {
        ContainerRelativeSize(.horizontal, length: { width, _ in
            min(420, max(230, width * 0.70))
        }) {
            HStack(spacing: 0) {
                if message?.direction == .outgoing {
                    Spacer()
                }
                VStack(
                    alignment: message?.direction == .outgoing
                        ? .trailing
                        : .leading,
                    spacing: 3
                ) {
                    // 音频气泡与文本、送达文案共用语义边缘；两种转写状态保持同宽。
                    bubbleView.containerRelativeSize(.horizontal)
                    if message?.deliveryText != nil {
                        deliveryStatusView
                    }
                }
                if message?.direction != .outgoing {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
    }

    /// 使用指定初始边框创建 `AudioBubbleCell`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        deliveryLabel.font = .preferredFont(forTextStyle: .caption2)
        deliveryLabel.adjustsFontForContentSizeCategory = true
        deliveryLabel.textColor = .secondaryLabel
        deliveryLabel.textAlignment = .natural
        isAccessibilityElement = false
    }

    /// 不支持从归档创建 `AudioBubbleCell`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 使用音频消息配置 Cell。
    ///
    /// - Parameters:
    ///   - message: 音频消息展示模型。
    ///   - playback: 页面级播放状态。
    ///   - playAccessibilityLabel: 本地化的“播放”操作。
    ///   - pauseAccessibilityLabel: 本地化的“暂停”操作。
    func configure(
        _ message: MessagePresentation,
        playback: PlaybackState,
        playAccessibilityLabel: String,
        pauseAccessibilityLabel: String
    ) {
        guard let attachment = message.audio else { return }
        self.message = message
        bubbleView.configure(
            attachment: attachment,
            direction: message.direction,
            playback: playback.messageID == message.id ? playback : .idle,
            playAccessibilityLabel: playAccessibilityLabel,
            pauseAccessibilityLabel: pauseAccessibilityLabel
        )
        bubbleView.playbackRequested = { [weak self] in
            guard let self,
                  let message = self.message,
                  let attachment = message.audio else { return }
            self.playbackRequested?(message.id, attachment)
        }
        deliveryStatusView.configure(message)
        deliveryLabel.text = message.deliveryText
        deliveryLabel.accessibilityLabel = message.deliveryText
        setNeedsQuickLayout()
    }

    /// 在不改变 Cell 消息身份的情况下更新播放进度。
    ///
    /// - Parameters:
    ///   - playback: 页面级播放状态。
    ///   - playAccessibilityLabel: 本地化的“播放”操作。
    ///   - pauseAccessibilityLabel: 本地化的“暂停”操作。
    func updatePlayback(
        _ playback: PlaybackState,
        playAccessibilityLabel: String,
        pauseAccessibilityLabel: String
    ) {
        guard let message, let attachment = message.audio else { return }
        bubbleView.configure(
            attachment: attachment,
            direction: message.direction,
            playback: playback.messageID == message.id ? playback : .idle,
            playAccessibilityLabel: playAccessibilityLabel,
            pauseAccessibilityLabel: pauseAccessibilityLabel
        )
    }

    /// 为复用清理 `AudioBubbleCell` 的内容与临时状态。
    override func prepareForReuse() {
        super.prepareForReuse()
        messageMenu.reset()
        message = nil
        playbackRequested = nil
        bubbleView.reset()
        deliveryStatusView.configure(nil)
        deliveryStatusView.retryRequested = nil
        deliveryLabel.text = nil
        deliveryLabel.accessibilityLabel = nil
        setNeedsQuickLayout()
    }
}
