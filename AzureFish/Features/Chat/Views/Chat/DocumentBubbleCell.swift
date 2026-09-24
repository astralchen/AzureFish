//
//  DocumentBubbleCell.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 在时间线中呈现文件或链接卡片、发送状态和保存入口的单元格。
@available(iOS 17.0, *)
final class DocumentBubbleCell: QuickLayoutCollectionViewCell {
    /// 随 Cell 复用重置的菜单辅助功能绑定。
    let messageMenu = MessageMenuAccessibility()

    /// 与编辑器共用内容配置和测量规则的附件卡片。
    let card = AttachmentCard(frame: .zero)
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
    /// 当前绑定的消息展示模型；未配置或复用清理后为 `nil`。
    private var message: MessagePresentation?
    /// 当前绑定身份，避免收回到复用后的文件卡片。
    var previewMessageID: Int? { message?.id }
    /// 用户打开当前消息附件时调用的闭包。
    var open: ((Attachment) -> Void)?
    /// 需要随单元格同步更新布局方向的内容视图。
    override var quickLayoutDirectionViews: [UIView] { super.quickLayoutDirectionViews + [card] }
    /// 定义 `DocumentBubbleCell` 的布局层级、间距和对齐方式。
    @LayoutBuilder override var body: Layout {
        ContainerRelativeSize(.horizontal, length: { width, _ in width * 0.70 }) {
            HStack(spacing: 0) {
                if message?.direction == .outgoing { Spacer() }
                VStack(alignment: message?.direction == .outgoing ? .trailing : .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        card.containerRelativeSize(.horizontal)
                        if showsSaveButton { saveButton.frame(width: 44, height: 44) }
                    }
                    if message?.deliveryText != nil { deliveryStatusView }
                }
                if message?.direction != .outgoing { Spacer() }
            }.frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 2)
        }
    }
    /// 使用指定初始边框创建 `DocumentBubbleCell`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        saveButton.addAction(UIAction { [weak self] _ in self?.saveRequested?() }, for: .touchUpInside)
        deliveryLabel.font = .preferredFont(forTextStyle: .caption2)
        deliveryLabel.adjustsFontForContentSizeCategory = true
        deliveryLabel.textColor = .secondaryLabel
        card.preferredSizeDidChange = { [weak self] in
            guard let self else { return }
            setNeedsQuickLayout()
            var ancestor = superview
            while let view = ancestor {
                if let collection = view as? UICollectionView {
                    collection.collectionViewLayout.invalidateLayout()
                    break
                }
                ancestor = view.superview
            }
        }
    }
    /// 不支持从归档创建 `DocumentBubbleCell`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 绑定文档消息，配置卡片打开动作、发送状态与附件保存入口。
    func configure(_ message: MessagePresentation, saveState: AttachmentSaveState = .available) {
        guard case .attachment(let attachment) = message.content else { return }
        self.message = message
        showsSaveButton = AttachmentSavePolicy.showsButton(for: message)
        saveButton.configure(saveState, isMedia: false)
        card.remove = nil
        card.configure(.init(attachment: attachment))
        card.open = { [weak self] in self?.open?(attachment) }
        deliveryStatusView.configure(message)
        deliveryLabel.text = message.deliveryText
        setNeedsQuickLayout()
    }
    /// 为复用清理 `DocumentBubbleCell` 的内容与临时状态。
    override func prepareForReuse() {
        super.prepareForReuse()
        messageMenu.reset()
        message = nil
        showsSaveButton = false
        saveRequested = nil
        open = nil
        card.open = nil
        deliveryStatusView.configure(nil)
        deliveryStatusView.retryRequested = nil
        deliveryLabel.text = nil
        saveButton.configure(.hidden, isMedia: false)
        setNeedsQuickLayout()
    }
}
