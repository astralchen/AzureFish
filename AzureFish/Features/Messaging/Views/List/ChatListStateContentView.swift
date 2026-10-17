import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 不属于列表数据的提示内容；标题和操作均支持动态字体。
final class ChatListStateContentView: QuickLayoutView {
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let retryButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var state: ChatListContentState = .empty
    var retry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [titleLabel, detailLabel] {
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = true
        }
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits.insert(.header)
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.titleLabel?.numberOfLines = 0
        retryButton.titleLabel?.textAlignment = .center
        retryButton.accessibilityIdentifier = "chat.list.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.retry?() }, for: .touchUpInside)
        spinner.isAccessibilityElement = false
        configure(.empty)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var body: Layout {
        VStack(alignment: .center, spacing: 8) {
            if state == .loading { spinner.frame(width: 24, height: 24) }
            titleLabel.resizable(axis: .horizontal)
            if state.detailKey != nil { detailLabel.resizable(axis: .horizontal) }
            if state == .failed {
                retryButton.resizable().frame(minWidth: 44, minHeight: 44)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    func configure(_ state: ChatListContentState) {
        self.state = state
        titleLabel.text = state.titleKey.isEmpty ? nil : Localization.text(state.titleKey)
        detailLabel.text = state.detailKey.map { Localization.text($0) }
        retryButton.setTitle(Localization.text("chat.list.retry"), for: .normal)
        retryButton.isHidden = state != .failed
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityIdentifier = "chat.list.state.\(state)"
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("聊天 · 搜索无结果") {
    let view = ChatListStateContentView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
    view.configure(.noResults)
    return view
}
#endif
