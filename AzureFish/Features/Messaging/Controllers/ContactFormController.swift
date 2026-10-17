import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 联系人表单使用独立滚动容器；重绘资料不替换正在编辑的输入对象。
class ContactFormController: LocalizedQuickLayoutHostingController {
    let scroll = QuickLayoutScrollView()
    var fields: [UIView] = []
    var controls: [UIButton] = []
    let status = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    var statusKey: String? { didSet { status.text = statusKey.map { Localization.text($0) }; setNeedsQuickLayout() } }
    var busy = false { didSet { updateBusy() } }
    override var body: Layout {
        ScrollView(scroll) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(fields) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity) }
                if busy { activity.frame(width: 44, height: 44) }
                status.resizable(axis: .horizontal)
                ForEach(controls) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 48) }
            }.frame(width: min(560, max(0, view.bounds.width - 40))).padding(.vertical, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaPadding(.all, 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); quickLayoutKeyboardSafeAreaBehavior = .docked()
        view.backgroundColor = .systemGroupedBackground; scroll.keyboardDismissMode = .interactive
        navigationItem.largeTitleDisplayMode = .never
        status.font = .preferredFont(forTextStyle: .footnote); status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0; status.textColor = .secondaryLabel; status.accessibilityIdentifier = "contacts.status"
    }
    func text(_ value: String, style: UIFont.TextStyle = .body) -> UILabel {
        let label = UILabel(); label.text = value; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        return label
    }
    func action(_ key: String, primary: Bool = false, destructive: Bool = false, perform: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = primary ? UIButton.Configuration.filled() : .plain()
        config.title = Localization.text(key); config.baseForegroundColor = destructive ? .systemRed : primary ? nil : .label
        if !primary { config.background.backgroundColor = .secondarySystemGroupedBackground }
        config.cornerStyle = .large; config.contentInsets = .init(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config; button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = key
        button.addAction(UIAction { _ in perform() }, for: .touchUpInside)
        return button
    }
    func updateBusy() {
        controls.forEach { $0.isEnabled = !busy; $0.configuration?.showsActivityIndicator = false }
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
        setNeedsQuickLayout()
        navigationItem.rightBarButtonItem?.isEnabled = !busy
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        status.text = statusKey.map { Localization.text($0) }
    }
    func report(_ error: any Error) { statusKey = contactErrorKey(error) }
}
