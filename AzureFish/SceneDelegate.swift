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
        if ProcessInfo.processInfo.arguments.contains("-chat-details-ui-test"), #available(iOS 26.0, *) {
            root = UINavigationController(rootViewController: ChatDetailsRegressionController())
        } else if let scenario = AccountDebugScenario.controller(arguments: ProcessInfo.processInfo.arguments) {
            root = scenario
        } else if ProcessInfo.processInfo.arguments.contains("-chat-ui-test-root") {
            if #available(iOS 26.0, *) { root = UINavigationController(rootViewController: ChatRegressionLaunchController()) }
            else { root = UINavigationController(rootViewController: LegacyChatViewController()) }
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
