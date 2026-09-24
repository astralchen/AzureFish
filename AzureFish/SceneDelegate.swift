import UIKit

/// 管理 AzureFish 场景窗口与聊天页面的语言环境。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// 场景持有的主窗口；场景断开时由系统释放。
    var window: UIWindow?

    /// 创建导航容器并在正常启动时直接展示聊天页。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Localization.start()
        let root: UIViewController
        if #available(iOS 26.0, *) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-chat-ui-test-root") {
                root = ChatRegressionLaunchController()
            } else {
                root = ChatViewController()
            }
            #else
            root = ChatViewController()
            #endif
        } else {
            root = LegacyChatViewController()
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: root)
        self.window = window
        Localization.register(window: window)
        window.makeKeyAndVisible()
    }

    /// 解除已断开窗口的本地化登记。
    func sceneDidDisconnect(_ scene: UIScene) {
        if let window { Localization.unregister(window: window) }
    }

    /// 场景激活时同步最新语言及界面方向。
    func sceneDidBecomeActive(_ scene: UIScene) {
        if let window { Localization.synchronize(window: window) }
    }

    /// 返回前台时检查系统首选语言是否变化。
    func sceneWillEnterForeground(_ scene: UIScene) {
        Localization.refreshSystemLocaleIfNeeded()
    }
}
