import UIKit
import QuickLayout
import QuickLayoutKit

/// 认证与资料流程的公共页面容器；滚动内容和底部动作共享键盘安全区域。
class AccountScreen: LocalizedQuickLayoutHostingController {
    let scroll = QuickLayoutScrollView()
    var content: [UIView] = []
    var actions: [UIView] = []
    var textReloaders: [() -> Void] = []
    var maximumWidth: CGFloat = 440
    var grouped = false
    private weak var focusedInput: UIView?
    private var width: CGFloat { min(maximumWidth, max(0, view.bounds.width - 48)) }
    private var scrollsActions: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }
    private func actionHeight(_ action: UIView) -> CGFloat {
        guard let button = action as? UIButton, let title = button.titleLabel else { return 52 }
        let insets = button.configuration?.contentInsets ?? .zero
        let size = title.sizeThatFits(CGSize(width: max(1, width - insets.leading - insets.trailing), height: .greatestFiniteMagnitude))
        return max(52, ceil(size.height + insets.top + insets.bottom))
    }
    private var actionStack: Layout {
        VStack(spacing: 12) {
            ForEach(actions) { $0.resizable(axis: .horizontal).frame(height: actionHeight($0)).frame(maxWidth: .infinity) }
        }.frame(width: width).padding(.bottom, 12)
    }
    override var body: Layout {
        VStack(spacing: 16) {
            ScrollView(scroll) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(content) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, alignment: .leading) }
                    // 无障碍字号下动作与表单一同滚动，避免底部动作挤占全部可用高度。
                    if scrollsActions { actionStack }
                }.frame(width: width).padding(.vertical, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !scrollsActions { actionStack }
        }.safeAreaPadding(.all, 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        quickLayoutKeyboardSafeAreaBehavior = .docked()
        view.backgroundColor = grouped ? .systemGroupedBackground : .systemBackground
        scroll.keyboardDismissMode = .interactive
        scroll.accessibilityIdentifier = "account.form.scroll"
        scroll.quickLayoutSemanticDirectionBehavior = .followEnclosingContainer
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification,
                     UITextView.textDidChangeNotification,
                     UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged(_:)), name: name, object: nil)
        }
    }
    @objc private func focusChanged(_ notification: Notification) {
        if let input = notification.object as? UIView, input.isDescendant(of: scroll) {
            focusedInput = input.isFirstResponder ? input : nil
            if notification.name == UITextView.textDidChangeNotification { setNeedsQuickLayout() }
        }
        DispatchQueue.main.async { [weak self] in self?.revealFocusedInput() }
    }
    private func revealFocusedInput() {
        guard let input = focusedInput, input.isFirstResponder else { return }
        view.layoutIfNeeded()
        // 容器已消费键盘安全区域，这里只滚动焦点，不叠加第二份键盘 contentInset。
        var rect = input.bounds
        if let text = input as? UITextView, let selection = text.selectedTextRange {
            rect = text.caretRect(for: selection.end)
        }
        let target = input.convert(rect, to: scroll).insetBy(dx: 0, dy: -12)
        scroll.scrollRectToVisible(target, animated: false)
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        textReloaders.forEach { $0() }
    }
    func label(_ key: String, style: UIFont.TextStyle = .body, secondary: Bool = false) -> UILabel {
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .natural
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        label.textColor = secondary ? .secondaryLabel : .label
        let update = {
            label.text = Localization.text(key)
            label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        }
        textReloaders.append(update); update()
        return label
    }
    func button(_ key: String, primary: Bool = false, destructive: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = primary ? UIButton.Configuration.filled() : .plain()
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        configuration.baseBackgroundColor = primary && destructive ? .systemRed : .systemBlue
        if destructive && !primary { configuration.baseForegroundColor = .systemRed }
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0; button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = key
        let update: () -> Void = { button.configuration?.title = Localization.text(key) }
        textReloaders.append(update); update()
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    func explainUnavailable() {
        showMessage("account.unavailable.feature")
    }
    func showMessage(_ key: String) {
        let alert = UIAlertController(title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        present(alert, animated: true)
    }
    func settingsMenus() {
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "circle.lefthalf.filled"), primaryAction: nil, menu: UIMenu(children: [UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion(AppearancePreference.menu().children) }
            }])),
            UIBarButtonItem(image: UIImage(systemName: "globe"), primaryAction: nil, menu: Localization.languageMenu())
        ]
        navigationItem.rightBarButtonItems?[0].accessibilityLabel = Localization.text("account.design.appearance")
        navigationItem.rightBarButtonItems?[1].accessibilityIdentifier = "demo.language.menu"
        navigationItem.rightBarButtonItems?[1].accessibilityLabel = Localization.text("account.design.language")
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Account screen") { AppNavigationController(rootViewController: AccountScreen()) }
#endif
