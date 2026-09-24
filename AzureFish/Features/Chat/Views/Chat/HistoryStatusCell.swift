import QuickLayout
import QuickLayoutKit
import UIKit

/// 状态始终占据相同的最小高度；重试按钮提供独立的 VoiceOver 操作。
final class HistoryStatusCell: QuickLayoutCollectionViewCell {
    /// 承载状态文字；仅在失败状态下接受点击并呈现按钮语义。
    private let button = UIButton(type: .system)
    /// 当前页加载期间旋转的系统指示器，停止后自动隐藏。
    private let indicator = UIActivityIndicatorView(style: .medium)
    /// 用户点击失败提示时通知会话视图，由页面路由到模型执行重试。
    var retry: (() -> Void)?

    /// 居中排列加载指示与文字，并提供至少 44 pt 高度的状态区域。
    override var body: Layout {
        HStack(spacing: 8) {
            indicator.fixedSize()
            button
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.horizontal, 16)
    }

    /// 配置随动态字体缩放的提示文字和弱引用的重试操作。
    ///
    /// - Parameter frame: 单元格的初始边框，最终尺寸由列表布局确定。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .touchUpInside)
    }

    /// 不支持归档初始化；该单元格由列表适配器通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 同步文案、交互、辅助功能语义与加载指示，并请求更新自身布局。
    ///
    /// 非失败状态使用静态文字语义，避免 VoiceOver 将不可操作的提示读成按钮。
    /// - Parameter presentation: 已完成本地化解析的顶部状态。
    func configure(_ presentation: HistoryStatusPresentation) {
        let failed = presentation.state == .failed
        button.setTitle(presentation.text, for: .normal)
        button.setTitleColor(failed ? .tintColor : .secondaryLabel, for: .normal)
        button.isUserInteractionEnabled = failed
        button.accessibilityTraits = failed ? .button : .staticText
        button.accessibilityIdentifier = failed ? "imessage.history.retry" : "imessage.history.status"
        button.accessibilityValue = String(describing: presentation.state)
        if presentation.state == .loading { indicator.startAnimating() } else { indicator.stopAnimating() }
        setNeedsQuickLayout()
    }

    /// 清除旧会话的重试回调并停止动画，防止复用后执行过期操作。
    override func prepareForReuse() {
        super.prepareForReuse()
        retry = nil
        indicator.stopAnimating()
    }
}
