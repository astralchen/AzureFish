import UIKit
import QuickLayout
import QuickLayoutKit

/// 附件标题与位置文案的玻璃视图，独立管理字号、截断、圆角和内容测量。
@available(iOS 26.0, *)
final class AttachmentPreviewTitleView: QuickLayoutVisualEffectView {
    /// 主标题随动态字体变化，过长时从中间截断。
    private let titleLabel = UILabel()
    /// 附件位置或文档页码，保留原辅助功能标识。
    private let positionLabel = UILabel()
    /// 外层与文档顶部避让共用的实际标题高度。
    var preferredHeight: CGFloat { max(44, titleLabel.font.lineHeight + positionLabel.font.lineHeight + 10) }

    /// 创建标题自身的持久视图，不依赖预览控制器。
    init() {
        super.init(effect: UIGlassEffect(style: .regular))
        clipsToBounds = true
        cornerConfiguration = .capsule()
        accessibilityIdentifier = "imessage.preview.title"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        positionLabel.font = .preferredFont(forTextStyle: .caption1)
        positionLabel.adjustsFontForContentSizeCategory = true
        positionLabel.adjustsFontSizeToFitWidth = true
        positionLabel.minimumScaleFactor = 0.6
        positionLabel.textColor = .secondaryLabel
        positionLabel.textAlignment = .center
        positionLabel.accessibilityIdentifier = "imessage.preview.position"
    }
    /// 标题仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 按字体行高布局，不让长标题改变按钮命中范围。
    override var body: Layout {
        VStack(spacing: 2) {
            titleLabel.resizable(axis: .horizontal).frame(height: titleLabel.font.lineHeight)
            positionLabel.resizable(axis: .horizontal).frame(height: positionLabel.font.lineHeight)
        }.padding(.horizontal, 16).padding(.vertical, 4)
    }
    /// 在外层给定的可用宽度内居中，至少保留默认标题宽度。
    func preferredWidth(available: CGFloat) -> CGFloat {
        let content = max(titleLabel.intrinsicContentSize.width, positionLabel.intrinsicContentSize.width) + 32
        return min(max(0, available), max(160, content))
    }
    /// 同步当前附件标题与位置，不涉及播放或显隐状态。
    func update(title: String, position: String) {
        titleLabel.text = title
        updatePosition(position)
    }
    /// 文档翻页只更新位置文案，保持主标题不变。
    func updatePosition(_ position: String) {
        positionLabel.text = position
        setNeedsQuickLayout()
    }
    /// 减少透明度时使用实体背景，其他情形保持系统玻璃。
    func applyAccessibilitySettings() {
        effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIGlassEffect(style: .regular)
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled ? .secondarySystemBackground : .clear
    }
}
