import QuickLayout
import QuickLayoutKit
import UIKit

/// 所有消息类型共用的状态栏。失败状态整体可重试，点击区至少 44 × 44 pt。
final class DeliveryStatusView: QuickLayoutButton {
    /// 显示本地化送达或已读文本的标签。
    let label = UILabel()
    /// 消息正在发送时显示的活动指示器。
    let progress = UIActivityIndicatorView(style: .medium)
    /// 发送失败时显示的重试符号图像视图。
    private let failureImage = UIImageView(image: UIImage(systemName: "exclamationmark.circle.fill"))
    /// 当前状态对应的消息标识符，用于发送重试请求。
    private var messageID: Int?
    /// 当前展示的发送状态；未绑定消息时为 `nil`。
    private var status: MessageDeliveryState?
    /// 当前是否需要显示发送进度。
    private var isSending: Bool { status == .sending }
    /// 当前是否允许重试发送。
    private var isFailed: Bool { status == .failed }
    /// 用户点击失败入口时调用的闭包，参数为待重试的消息身份。
    var retryRequested: ((Int) -> Void)?

    /// 按状态组合图标与文本，并保证失败入口的最小点击区域。
    override var body: Layout {
        HStack(spacing: 6) {
            if isSending {
                progress.resizable().frame(width: 20, height: 20)
            } else if isFailed {
                failureImage.resizable().frame(width: 20, height: 20)
            }
            label.fixedSize(axis: .vertical)
        }
        .frame(minWidth: isFailed ? 44 : 0, minHeight: isFailed ? 44 : 0, alignment: .leading)
    }

    /// 使用指定初始边框创建 `DeliveryStatusView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        failureImage.tintColor = .systemRed
        isAccessibilityElement = true
        addAction(UIAction { [weak self] _ in
            guard let self, isFailed, let messageID else { return }
            retryRequested?(messageID)
        }, for: .touchUpInside)
        configure(nil)
    }

    /// 不支持从归档创建 `DeliveryStatusView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// VoiceOver 与触摸共用失败重试入口。
    override func accessibilityActivate() -> Bool {
        guard isEnabled, isFailed else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    /// 绑定消息发送状态，并更新文字、进度、失败入口与可交互性。
    func configure(_ message: MessagePresentation?) {
        messageID = message?.id
        status = message?.deliveryState
        label.text = message?.deliveryText
        label.textColor = isFailed ? .systemRed : .secondaryLabel
        if isSending { progress.startAnimating() } else { progress.stopAnimating() }
        isUserInteractionEnabled = isFailed
        accessibilityLabel = message?.deliveryText
        accessibilityHint = isFailed ? Localization.text("imessage.status.retry.hint") : nil
        accessibilityTraits = isFailed ? .button : .staticText
        accessibilityIdentifier = isFailed ? "imessage.message.retry" : "imessage.message.status"
        setNeedsQuickLayout()
    }
}
