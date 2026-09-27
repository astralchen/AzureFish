import UIKit
import QuickLayout
import QuickLayoutKit

/// 原生输入控件与 QuickLayout 标签组合，输入在本地化刷新时保持原对象和选区。
final class AccountField: QuickLayoutView {
    let input = UITextField()
    private let label = UILabel()
    private let fill = UIView()
    private let reveal = UIButton(type: .system)
    private let key: String
    private let secure: Bool
    init(key: String, secure: Bool = false, identifier: String) {
        self.key = key; self.secure = secure
        super.init(frame: .zero)
        input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
        input.isSecureTextEntry = secure; input.autocorrectionType = .no; input.spellCheckingType = .no
        input.accessibilityIdentifier = identifier
        if secure { input.textContentType = .password; input.semanticContentAttribute = .forceLeftToRight; input.autocapitalizationType = .none; input.keyboardType = .asciiCapable }
        label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel; label.numberOfLines = 0; label.textAlignment = .natural
        reveal.setImage(UIImage(systemName: "eye"), for: .normal)
        reveal.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.input.isSecureTextEntry.toggle()
            self.reloadText()
        }, for: .touchUpInside)
        fill.backgroundColor = .secondarySystemBackground; fill.layer.cornerRadius = 14
        reloadText()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reloadText() {
        label.text = Localization.text(key); input.accessibilityLabel = label.text
        label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        input.placeholder = label.text
        reveal.accessibilityLabel = Localization.text("account.design.\(input.isSecureTextEntry ? "showPassword" : "hidePassword")")
        reveal.setImage(UIImage(systemName: input.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
        setNeedsQuickLayout()
    }
    override var body: Layout {
        VStack(alignment: .leading, spacing: 8) {
            label
            ZStack {
                fill.resizable()
                HStack(spacing: 4) {
                    input.resizable().frame(minHeight: 52)
                    if secure { reveal.resizable().frame(width: 44, height: 52) }
                }.padding(.horizontal, 16)
            }.frame(height: max(52, input.font!.lineHeight + 24))
        }
    }
}

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
    override var body: Layout {
        VStack(spacing: 16) {
            ScrollView(scroll) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(content) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, alignment: .leading) }
                }.frame(width: width).padding(.vertical, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) { ForEach(actions) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 52) } }
                .frame(width: width).padding(.bottom, 12)
        }.safeAreaPadding(.all, 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        quickLayoutKeyboardSafeAreaBehavior = .docked()
        view.backgroundColor = grouped ? .systemGroupedBackground : .systemBackground
        scroll.keyboardDismissMode = .interactive
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
        configuration.baseBackgroundColor = .systemBlue
        if destructive { configuration.baseForegroundColor = .systemRed }
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
        navigationItem.rightBarButtonItems?[1].accessibilityLabel = Localization.text("account.design.language")
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Account field") { QuickLayoutHostingController { AccountField(key: "account.design.password", secure: true, identifier: "preview").padding(24) } }
@available(iOS 17.0, *)
#Preview("Account screen") { UINavigationController(rootViewController: AccountScreen()) }
#endif
