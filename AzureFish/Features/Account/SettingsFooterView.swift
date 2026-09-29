import UIKit
import QuickLayout
import QuickLayoutKit

/// 设置分组的多行说明，按容器宽度与动态字体测量高度。
final class SettingsFooterView: QuickLayoutCollectionReusableView {
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        // Supplementary 的初始高度只是估值，不能用它限制多行说明的测量。
        label.resizable(axis: .horizontal).fixedSize(axis: .vertical).padding(.horizontal, 16).padding(.vertical, 8)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // UIKit 首次只给 estimated 高度；按实际宽度无高度上限测量，避免长说明溢出 supplementary。
        let text = label.sizeThatFits(CGSize(width: max(1, size.width - 32), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: ceil(text.height) + 16)
    }
    func configure(key: String) {
        label.text = Localization.text(key)
        label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        label.accessibilityIdentifier = key
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Settings footer") {
    let footer = SettingsFooterView(frame: .zero)
    footer.configure(key: "account.design.appearanceHelp")
    return QuickLayoutHostingController { footer.resizable(axis: .horizontal).padding(24) }
}
@available(iOS 17.0, *)
#Preview("Settings footer · large text") {
    let footer = SettingsFooterView(frame: .zero)
    footer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    footer.configure(key: "account.design.languageHelp")
    return QuickLayoutHostingController { footer.resizable(axis: .horizontal).padding(24) }
}
#endif
