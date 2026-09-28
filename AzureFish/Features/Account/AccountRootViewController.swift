import AzureFishAPI
import AzureFishChat
import UIKit
import QuickLayoutKit

/// 只在认证阶段改变时切换根容器，外观和语言变化保持当前导航栈。
final class AccountRootViewController: LocalizedViewController, UITabBarControllerDelegate {
    private let session: SessionCoordinator
    private var renderedIdentity: String?
    private var renderedPhase: SessionCoordinator.Phase?
    private var current: UIViewController?
    private weak var tabs: UITabBarController?
    private var chatRuntime: ChatRuntime?
    private var tabRestored = false
    private var bannerCoordinator: ChatIncomingBannerCoordinator?
    init(session: SessionCoordinator = .configured()) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        session.didChange = { [weak self] in self?.render() }
        render()
        Task { await session.restore() }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bannerCoordinator?.updateActivity()
    }
    private func render() {
        guard renderedPhase != session.phase || renderedIdentity != session.sessionIdentity else {
            chatRuntime?.publish()
            (current as? UINavigationController)?.viewControllers.compactMap { $0 as? AccountRecoveryViewController }.forEach { $0.reloadLocalizedContent() }
            return
        }
        if session.phase != .signedIn || renderedIdentity != session.sessionIdentity { bannerCoordinator?.stop(); bannerCoordinator = nil; chatRuntime?.stop(); chatRuntime = nil; tabRestored = false }
        renderedPhase = session.phase
        renderedIdentity = session.sessionIdentity
        let next: UIViewController
        switch session.phase {
        case .welcome: next = UINavigationController(rootViewController: WelcomeViewController(session: session))
        case .restoring, .recovery: next = UINavigationController(rootViewController: AccountRecoveryViewController(session: session))
        case .signedIn:
            let tabs = UITabBarController()
            let runtime = ChatRuntime(session: session); chatRuntime = runtime
            let chat = ChatSplitViewController(runtime: runtime)
            let contacts = ContactsSplitViewController(runtime: runtime)
            let me = ProfileViewController(session: session, runtime: runtime)
            tabs.viewControllers = [chat, contacts, UINavigationController(rootViewController: me)]
            runtime.openConversation = { [weak tabs, weak chat] conversation in
                tabs?.selectedIndex = 0; chat?.open(conversation)
            }
            tabs.selectedIndex = 0; tabs.delegate = self
            _ = runtime.observe { [weak self, weak runtime] in
                guard let self, let runtime, chatRuntime === runtime else { return }
                updateUnreadBadges()
                guard !tabRestored, let store = runtime.engine?.store else { return }
                tabRestored = true
                Task { [weak self] in
                    let selected: Int? = try? await store.meta("selectedTab")
                    guard let self, chatRuntime === runtime else { return }
                    if let selected, (0...2).contains(selected) { self.tabs?.selectedIndex = selected }
                }
            }
            bannerCoordinator = ChatIncomingBannerCoordinator(host: self, runtime: runtime) { [weak tabs, weak chat] conversation in
                tabs?.selectedIndex = 0
                chat?.open(conversation)
            }
            runtime.start()
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
        if let controllers = tabs?.viewControllers, controllers.count == 3 { controllers[1].tabBarItem = UITabBarItem(title: Localization.text("chat.live.contacts"), image: UIImage(systemName: "person.2"), tag: 1) }
        tabs?.viewControllers?.last?.tabBarItem = UITabBarItem(title: Localization.text("account.design.me"), image: UIImage(systemName: "person.crop.circle"), tag: 2)
        updateUnreadBadges()
        bannerCoordinator?.reloadLocalizedContent()
    }
    private func updateUnreadBadges() {
        guard let runtime = chatRuntime, let controllers = tabs?.viewControllers, controllers.count == 3 else { return }
        // 数量来自全部会话的权威未读水位，不受当前搜索或所选 Tab 影响。
        let unread = runtime.conversations.reduce(Int64(0)) { total, conversation in
            min(100, total + min(100, max(0, conversation.readState.unread)))
        }
        let pending = runtime.contacts.filter { $0.requestState == "pending" && $0.requesterID != runtime.userID && !$0.isBlocked }.count
        for (index, count) in [(0, unread), (1, Int64(pending))] {
            controllers[index].tabBarItem.badgeValue = count == 0 ? nil : count > 99 ? "99+" : String(count)
            controllers[index].tabBarItem.badgeColor = .systemRed
        }
    }
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        let index = tabBarController.selectedIndex
        Task { try? await chatRuntime?.engine?.store.setMeta(index, id: "selectedTab") }
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
