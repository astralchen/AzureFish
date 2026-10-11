import UIKit

/// 管理 AzureFish 场景窗口、认证入口与语言环境。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// 场景持有的主窗口；场景断开时由系统释放。
    var window: UIWindow?

    /// 在首帧前恢复安装偏好，正常启动经过会话恢复。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Localization.start()
        let root: UIViewController
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-moments-video-demo") {
            root = AppNavigationController(rootViewController: MomentsVideoDemoController())
        } else if ProcessInfo.processInfo.arguments.contains("-moments-layout-demo") {
            root = AppNavigationController(rootViewController: MomentsViewController(runtime: MomentsPreviewData.layoutComparisonRuntime()))
        } else if ProcessInfo.processInfo.arguments.contains("-moments-ui-test") {
            // UI 回归使用确定性本地样例和真实标签容器，页面浏览不依赖账号登录。
            let arguments = ProcessInfo.processInfo.arguments
            let countIndex = arguments.firstIndex(of: "-moments-photo-count").map { $0 + 1 }
            let imageCount = countIndex.flatMap { arguments.indices.contains($0) ? Int(arguments[$0]) : nil } ?? 9
            let runtime = MomentsPreviewData.runtime(imageCount: imageCount)
            if let index = arguments.firstIndex(of: "-moments-pagination-state"), arguments.indices.contains(index + 1) {
                runtime.previewPagination = MomentsPaginationState(rawValue: arguments[index + 1])
            }
            let tabs = UITabBarController()
            let chat = UIViewController(), contacts = UIViewController(), me = UIViewController()
            let discover = DiscoverTabViewController(runtime: runtime)
            tabs.viewControllers = [chat, contacts, discover, me]
            for (index, key) in ["account.design.chat", "chat.live.contacts", "moments.discover", "account.design.me"].enumerated() {
                tabs.viewControllers?[index].tabBarItem = UITabBarItem(title: Localization.text(key), image: UIImage(systemName: ["bubble.left.and.bubble.right", "person.2", "safari", "person.crop.circle"][index]), tag: index)
                tabs.viewControllers?[index].tabBarItem.accessibilityIdentifier = "app.tab.\(index)"
            }
            tabs.selectedIndex = 2; root = tabs
        } else if ProcessInfo.processInfo.arguments.contains("-chat-details-ui-test"), #available(iOS 26.0, *) {
            root = AppNavigationController(rootViewController: ChatDetailsRegressionController())
        } else if let scenario = AccountDebugScenario.controller(arguments: ProcessInfo.processInfo.arguments) {
            root = scenario
        } else if ProcessInfo.processInfo.arguments.contains("-chat-ui-test-root") {
            if #available(iOS 26.0, *) { root = AppNavigationController(rootViewController: ChatRegressionLaunchController()) }
            else { root = AppNavigationController(rootViewController: LegacyChatViewController()) }
        } else {
            root = AccountRootViewController()
        }
        #else
        root = AccountRootViewController()
        #endif
        let window = ChatInteractionWindow(windowScene: windowScene)
        AppearancePreference.apply(to: window)
        window.rootViewController = root
        self.window = window
        Localization.register(window: window)
        window.makeKeyAndVisible()
    }

    /// 解除已断开窗口的本地化登记。
    func sceneDidDisconnect(_ scene: UIScene) {
        (window?.rootViewController as? AccountRootViewController)?.setSceneActive(false)
        if let window { Localization.unregister(window: window) }
    }

    /// 场景激活时同步最新语言及界面方向。
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let window { Localization.synchronize(window: window) }
        (window?.rootViewController as? AccountRootViewController)?.setSceneActive(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? AccountRootViewController)?.setSceneActive(false)
    }

    /// 返回前台时检查系统首选语言是否变化。
    func sceneWillEnterForeground(_ scene: UIScene) {
        Localization.refreshSystemLocaleIfNeeded()
    }
}
