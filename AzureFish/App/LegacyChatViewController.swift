import UIKit

/// iOS 15～25 的聊天入口，后续在此接入不依赖液态玻璃的聊天界面。
final class LegacyChatViewController: LocalizedViewController {
    /// 显示旧系统聊天界面的适配状态。
    private let statusLabel = UILabel()

    /// 使用 iOS 15 支持的 UIKit 组件建立基础页面。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
    }

    /// 语言切换后同步基础页面标题和适配提示。
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        title = "AzureFish"
        statusLabel.text = Localization.text("imessage.legacy.pending")
    }
}
