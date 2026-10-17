import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

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
#endif
