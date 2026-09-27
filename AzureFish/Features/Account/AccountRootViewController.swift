import UIKit
import QuickLayoutKit

/// 只在认证阶段改变时切换根容器，外观和语言变化保持当前导航栈。
final class AccountRootViewController: LocalizedViewController {
    private let session: SessionCoordinator
    private var renderedPhase: SessionCoordinator.Phase?
    private var current: UIViewController?
    private weak var tabs: UITabBarController?
    init(session: SessionCoordinator = .configured()) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        session.didChange = { [weak self] in self?.render() }
        render()
        Task { await session.restore() }
    }
    private func render() {
        guard renderedPhase != session.phase else {
            (current as? UINavigationController)?.viewControllers.compactMap { $0 as? AccountRecoveryViewController }.forEach { $0.reloadLocalizedContent() }
            return
        }
        renderedPhase = session.phase
        let next: UIViewController
        switch session.phase {
        case .welcome: next = UINavigationController(rootViewController: WelcomeViewController(session: session))
        case .restoring, .recovery: next = UINavigationController(rootViewController: AccountRecoveryViewController(session: session))
        case .signedIn:
            let tabs = UITabBarController()
            let chat = LocalChatEntryViewController()
            let me = ProfileViewController(session: session)
            tabs.viewControllers = [UINavigationController(rootViewController: chat), UINavigationController(rootViewController: me)]
            tabs.selectedIndex = 1
            self.tabs = tabs; next = tabs
        }
        current?.willMove(toParent: nil); current?.view.removeFromSuperview(); current?.removeFromParent()
        addChild(next); view.addSubview(next.view)
        // 系统容器托管边界使用 Auto Layout，具体页面由 QuickLayout 驱动。
        next.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([next.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            next.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), next.view.topAnchor.constraint(equalTo: view.topAnchor),
            next.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        next.didMove(toParent: self); current = next; reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        tabs?.viewControllers?.first?.tabBarItem = UITabBarItem(title: Localization.text("account.design.chat"), image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0)
        tabs?.viewControllers?.last?.tabBarItem = UITabBarItem(title: Localization.text("account.design.me"), image: UIImage(systemName: "person.crop.circle"), tag: 1)
    }
}

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
#Preview("Account root") { AccountRootViewController() }
@available(iOS 17.0, *)
#Preview("Local chat boundary") { LocalChatEntryViewController() }
#endif
