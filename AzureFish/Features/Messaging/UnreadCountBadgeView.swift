import QuickLayout
import QuickLayoutKit
import UIKit

/// 将数量文字放入独立的徽标容器，避免列表 accessory 按 UILabel 的文字基线偏移整个红色背景。
final class UnreadCountBadgeView: QuickLayoutView {
    let textLabel = UILabel()

    init(text: String, dot: Bool = false) {
        super.init(frame: .zero)
        textLabel.text = dot ? nil : text
        textLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        textLabel.textColor = .white
        textLabel.textAlignment = .center
        textLabel.isAccessibilityElement = false
        isAccessibilityElement = false
        backgroundColor = .systemRed
        layer.cornerRadius = dot ? 5 : 11
        clipsToBounds = true
        let textSize = textLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 22))
        frame.size = dot ? CGSize(width: 10, height: 10) : CGSize(width: max(22, ceil(textSize.width) + 12), height: 22)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var body: Layout {
        textLabel.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("数量徽标 · 1") { UnreadCountBadgeView(text: "1") }
@available(iOS 17.0, *)
#Preview("数量徽标 · 99+") { UnreadCountBadgeView(text: "99+") }
@available(iOS 17.0, *)
#Preview("手动未读 · 红点") { UnreadCountBadgeView(text: "", dot: true) }
#endif
