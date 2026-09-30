import UIKit

/// 按导航栈位置统一管理底部栏显隐的系统导航容器。
///
/// 根控制器的 `hidesBottomBarWhenPushed` 为 `false`，其余控制器为 `true`。
/// 入栈及替换导航栈时覆盖页面原有标记；页面自身不应再修改该属性。
/// 当前 Tab 的可见导航栈（包括外层栈）任一离开根控制器时隐藏底部栏。
/// 分栏折叠后压入主栈的详情容器也属于非根控制器，转场和安全区域由 UIKit 管理。
/// 此容器使用自身作为导航代理，以同步嵌套分栏内的系统 TabBar。
final class AppNavigationController: UINavigationController, UINavigationControllerDelegate {
    private weak var transitionTarget: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        synchronizeTabBar(animated: animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 分栏折叠、展开及 Tab 切换可能只改变可见容器，不发生 push/pop。
        synchronizeTabBar(animated: false)
    }

    override var viewControllers: [UIViewController] {
        get { super.viewControllers }
        set {
            prepareBottomBarVisibility(for: newValue)
            super.viewControllers = newValue
        }
    }

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        prepareBottomBarVisibility(for: viewControllers)
        super.setViewControllers(viewControllers, animated: animated)
    }

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        // 根控制器初始化也经过 push；空栈的首个页面必须清除复用时留下的隐藏标记。
        viewController.hidesBottomBarWhenPushed = !viewControllers.isEmpty
        super.pushViewController(viewController, animated: animated)
    }

    private func prepareBottomBarVisibility(for controllers: [UIViewController]) {
        for (index, controller) in controllers.enumerated() {
            controller.hidesBottomBarWhenPushed = index != 0
        }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        transitionTarget = viewController
        synchronizeTabBar(animated: animated)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // 交互式返回取消后，UIKit 会重新报告原页面，按最终栈恢复显隐。
        transitionTarget = nil
        synchronizeTabBar(animated: false)
    }

    private func synchronizeTabBar(animated: Bool) {
        // 老系统保留 hidesBottomBarWhenPushed 的原生路径。新系统提供容器级 API，
        // 可处理 UITabBarController → 自适应容器 → UISplitViewController → 导航栈。
        guard #available(iOS 18.0, *), let tabs = tabBarController,
              let selected = tabs.selectedViewController else { return }
        let navigations = Self.navigationControllers(in: selected)
        guard navigations.contains(where: { $0 === self }) else { return }
        let hidden = navigations.contains { navigation in
            guard Self.isVisible(navigation, in: tabs) else { return false }
            let target = navigation.transitionTarget ?? navigation.topViewController
            return target != nil && target !== navigation.viewControllers.first
        }
        guard tabs.isTabBarHidden != hidden else { return }
        tabs.setTabBarHidden(hidden, animated: animated)
    }

    private static func navigationControllers(in controller: UIViewController) -> [AppNavigationController] {
        if let navigation = controller as? AppNavigationController {
            // 同时检查外层栈；内层详情仍在根位置，不能覆盖外层已经 push 的状态。
            let target = navigation.transitionTarget ?? navigation.topViewController
            let nested = target.map { navigationControllers(in: $0) } ?? []
            return [navigation] + nested
        }
        return controller.children.flatMap { navigationControllers(in: $0) }
    }

    private static func isVisible(_ navigation: AppNavigationController, in tabs: UITabBarController) -> Bool {
        guard let view = navigation.viewIfLoaded, view.window != nil,
              view.convert(view.bounds, to: tabs.view).intersects(tabs.view.bounds) else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha == 0 { return false }
            ancestor = current.superview
        }
        return true
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("根页显示 TabBar") {
    let navigation = AppNavigationController(rootViewController: AccountSettingsViewController())
    navigation.tabBarItem = UITabBarItem(title: Localization.text("account.design.settings"), image: UIImage(systemName: "gearshape"), tag: 0)
    let tabs = UITabBarController()
    tabs.viewControllers = [navigation]
    return tabs
}

@available(iOS 17.0, *)
#Preview("非根页隐藏 TabBar") {
    let navigation = AppNavigationController(rootViewController: AccountSettingsViewController())
    navigation.tabBarItem = UITabBarItem(title: Localization.text("account.design.settings"), image: UIImage(systemName: "gearshape"), tag: 0)
    let tabs = UITabBarController()
    tabs.viewControllers = [navigation]
    navigation.pushViewController(AccountSettingsViewController(page: .appearance), animated: false)
    return tabs
}
#endif
