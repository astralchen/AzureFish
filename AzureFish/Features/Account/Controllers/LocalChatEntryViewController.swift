import AzureFishAPI
import AzureFishChat
import UIKit
import QuickLayoutKit

/// 聊天继续使用独立本地演示，不把既有草稿解释为登录账号的数据。
final class LocalChatEntryViewController: AccountScreen {
    override var localizedTitleKey: String? { "account.design.chat" }
    override func viewDidLoad() {
        super.viewDidLoad()
        content = [label("account.design.localDemo", style: .title1), label("account.design.demoHelp", secondary: true)]
        actions = [button("account.design.continue", primary: true) { [weak self] in
            let controller: UIViewController
            if #available(iOS 26.0, *) { controller = ChatViewController() }
            else { controller = LegacyChatViewController() }
            self?.navigationController?.pushViewController(controller, animated: true)
        }]
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Local chat boundary") { LocalChatEntryViewController() }
#endif
