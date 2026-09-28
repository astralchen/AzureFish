import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 会话列表的内容状态；空数组只有在完整快照已落库后才表示没有聊天。
enum ChatListContentState: Equatable {
    case content, loading, empty, noResults, failed, storageFailure

    static func resolve(hasSnapshot: Bool, synchronization: ChatSynchronizationState,
                        storageFailure: Bool, totalCount: Int, matchCount: Int,
                        searching: Bool) -> Self {
        if storageFailure { return .storageFailure }
        if matchCount > 0 { return .content }
        if !hasSnapshot && totalCount == 0 {
            return synchronization == .failed ? .failed : .loading
        }
        return searching ? .noResults : .empty
    }

    var titleKey: String {
        switch self {
        case .content: return ""
        case .loading: return "chat.list.loading"
        case .empty: return "chat.list.empty"
        case .noResults: return "chat.list.noResults"
        case .failed: return "chat.list.failed"
        case .storageFailure: return "chat.live.storageFailure"
        }
    }
    var detailKey: String? {
        switch self {
        case .empty: return "chat.list.emptyHelp"
        case .noResults: return "chat.list.searchHelp"
        case .failed: return "chat.list.retryHelp"
        default: return nil
        }
    }
}

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
        titleLabel.text = Localization.text(state.titleKey)
        detailLabel.text = state.detailKey.map { Localization.text($0) }
        retryButton.setTitle(Localization.text("chat.list.retry"), for: .normal)
        retryButton.isHidden = state != .failed
        if state == .loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityIdentifier = "chat.list.state.\(state)"
        setNeedsQuickLayout()
    }
}

/// 在列表可见区域中居中提示，空间不足时允许滚动阅读完整文字。
final class ChatListStateView: UIView {
    let content = ChatListStateContentView(frame: .zero)
    private let scroll = UIScrollView()
    var viewportInsets: UIEdgeInsets = .zero { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        addSubview(scroll)
        scroll.addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // backgroundView 跟随列表视口；这里只避让系统 inset，不再次缩小集合视图。
        let usable = bounds.inset(by: viewportInsets)
        scroll.frame = CGRect(x: usable.minX, y: usable.minY,
                              width: max(0, usable.width), height: max(0, usable.height))
        let width = scroll.bounds.width
        let size = content.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = max(1, size.height)
        content.frame = CGRect(x: 0, y: max(0, (scroll.bounds.height - height) / 2),
                               width: width, height: height)
        scroll.contentSize = CGSize(width: width, height: max(scroll.bounds.height, height))
        scroll.isScrollEnabled = height > scroll.bounds.height
        content.setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("聊天 · 暂无聊天") {
    let view = ChatListStateView(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
    view.backgroundColor = .systemBackground
    return view
}
@available(iOS 17.0, *)
#Preview("聊天 · 加载失败") {
    let view = ChatListStateView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
    view.content.configure(.failed)
    view.backgroundColor = .systemBackground
    return view
}
@available(iOS 17.0, *)
#Preview("聊天 · 搜索无结果") {
    let view = ChatListStateContentView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
    view.configure(.noResults)
    return view
}
#endif
