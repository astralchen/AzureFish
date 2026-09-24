//
//  MediaBubbleCell.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 在时间线中显示媒体内容、发送状态和保存入口的自适应单元格。
final class MediaBubbleCell: QuickLayoutCollectionViewCell {
    /// 随 Cell 复用重置的菜单辅助功能绑定。
    let messageMenu = MessageMenuAccessibility()

    /// 显示单图气泡或可切换媒体堆叠的视图。
    let mediaView = MediaMessageView()
    /// 显示发送进度、失败入口及送达文本的状态视图。
    let deliveryStatusView = DeliveryStatusView()
    /// 状态视图中用于显示本地化送达文本的标签。
    var deliveryLabel: UILabel { deliveryStatusView.label }
    /// 用于将收到的附件保存到系统位置的按钮。
    let saveButton = AttachmentSaveButton()
    /// 用户请求保存当前附件时调用的闭包。
    var saveRequested: (() -> Void)?
    /// 指示当前布局是否为附件保存入口保留空间的布尔值。
    private var showsSaveButton = false
    /// 当前 Cell 绑定的消息身份，用于拒绝复用后的转场目标。
    var previewMessageID: Int? { message?.id }
    /// 当前绑定的消息展示模型；未配置或复用清理后为 `nil`。
    private var message: MessagePresentation?
    /// 媒体封面变化时向时间线转发消息身份和索引的闭包。
    var frontIndexDidChange: ((Int, Int) -> Void)?
    /// 向页面请求媒体全屏预览的闭包，携带消息、媒体组和起始索引。
    var previewRequested: ((Int, MediaGroupAttachment, Int) -> Void)?

    /// 需要随单元格同步更新布局方向的内容视图。
    override var quickLayoutDirectionViews: [UIView] {
        super.quickLayoutDirectionViews + [mediaView]
    }

    /// 定义 `MediaBubbleCell` 的布局层级、间距和对齐方式。
    @LayoutBuilder
    override var body: Layout {
        HStack(spacing: 0) {
            if message?.direction == .outgoing { Spacer() }
            VStack(
                alignment: message?.direction == .outgoing ? .trailing : .leading,
                spacing: 3
            ) {
                HStack(spacing: 8) {
                    mediaView
                    if showsSaveButton {
                        saveButton.frame(width: 44, height: 44).padding(.top, mediaView.headerHeight)
                    }
                }
                if message?.deliveryText != nil { deliveryStatusView }
            }
            if message?.direction != .outgoing { Spacer() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// 使用指定初始边框创建 `MediaBubbleCell`，并配置其子视图和默认外观。
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
        saveButton.addAction(UIAction { [weak self] _ in self?.saveRequested?() }, for: .touchUpInside)
        isAccessibilityElement = false
        mediaView.frontIndexDidChange = { [weak self] messageID, index in
            self?.frontIndexDidChange?(messageID, index)
            self?.messageMenu.refreshAccessibility()
        }
        mediaView.previewRequested = { [weak self] messageID, group, index in
            self?.previewRequested?(messageID, group, index)
        }
    }

    /// 不支持从归档创建 `MediaBubbleCell`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 配置媒体消息的内容、封面位置、本地化文字与附件保存状态。
    func configure(
        _ message: MessagePresentation,
        group: MediaGroupAttachment,
        frontIndex: Int,
        strings: MediaStrings,
        saveState: AttachmentSaveState = .available
    ) {
        self.message = message
        showsSaveButton = AttachmentSavePolicy.showsButton(for: message)
        saveButton.configure(saveState, isMedia: true)
        deliveryStatusView.configure(message)
        deliveryLabel.text = message.deliveryText
        deliveryLabel.accessibilityLabel = message.deliveryText
        mediaView.configure(
            messageID: message.id,
            direction: message.direction,
            group: group,
            frontIndex: frontIndex,
            strings: strings
        )
        setNeedsQuickLayout()
    }

    /// 为复用清理 `MediaBubbleCell` 的内容与临时状态。
    override func prepareForReuse() {
        super.prepareForReuse()
        messageMenu.reset()
        message = nil
        showsSaveButton = false
        saveRequested = nil
        saveButton.configure(.hidden, isMedia: true)
        deliveryStatusView.configure(nil)
        deliveryStatusView.retryRequested = nil
        deliveryLabel.text = nil
        deliveryLabel.accessibilityLabel = nil
        mediaView.reset()
        setNeedsQuickLayout()
    }
}
