import Testing
import UIKit
@testable import AzureFish

@Suite("统一导航底部栏策略", .serialized)
@MainActor
struct AppNavigationControllerTests {
    @Test func initializationAndPushIntoEmptyStackClearOldRootFlag() {
        let root = UIViewController()
        root.hidesBottomBarWhenPushed = true
        let navigation = AppNavigationController(rootViewController: root)
        #expect(navigation.viewControllers.first === root)
        #expect(!root.hidesBottomBarWhenPushed)

        let empty = AppNavigationController()
        let reused = UIViewController()
        reused.hidesBottomBarWhenPushed = true
        empty.pushViewController(reused, animated: false)
        #expect(!reused.hidesBottomBarWhenPushed)
    }

    @Test func multiplePushesAndPopsPreserveRootPolicy() {
        let root = UIViewController()
        let navigation = AppNavigationController(rootViewController: root)
        let detail = UIViewController()
        let nested = UIViewController()
        navigation.pushViewController(detail, animated: false)
        navigation.pushViewController(nested, animated: false)
        #expect(!root.hidesBottomBarWhenPushed)
        #expect(detail.hidesBottomBarWhenPushed)
        #expect(nested.hidesBottomBarWhenPushed)
        #expect(navigation.popViewController(animated: false) === nested)
        #expect(navigation.topViewController === detail)
        #expect(detail.hidesBottomBarWhenPushed)
        navigation.popToRootViewController(animated: false)
        #expect(navigation.topViewController === root)
        #expect(!root.hidesBottomBarWhenPushed)
    }

    @Test(arguments: [false, true])
    func replacingStackPromotesReusedDetailToRoot(animated: Bool) async throws {
        let root = UIViewController()
        let detail = UIViewController()
        let navigation = AppNavigationController(rootViewController: root)
        navigation.pushViewController(detail, animated: false)
        navigation.setViewControllers([detail, root], animated: animated)
        #expect(!detail.hidesBottomBarWhenPushed)
        #expect(root.hidesBottomBarWhenPushed)
        // 动画期间 topViewController 可能仍指向转场前的页面，等待 UIKit 完成切换。
        for _ in 0..<100 where navigation.topViewController !== root {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(navigation.topViewController === root)
        navigation.setViewControllers([root], animated: false)
        #expect(!root.hidesBottomBarWhenPushed)
    }

    @Test func directStackAssignmentNormalizesEveryController() {
        let root = UIViewController()
        root.hidesBottomBarWhenPushed = true
        let detail = UIViewController()
        let nested = UIViewController()
        let navigation = AppNavigationController()
        navigation.viewControllers = [root, detail, nested]
        #expect(!root.hidesBottomBarWhenPushed)
        #expect(detail.hidesBottomBarWhenPushed)
        #expect(nested.hidesBottomBarWhenPushed)
        navigation.viewControllers = [nested]
        #expect(!nested.hidesBottomBarWhenPushed)
    }

    @Test func splitContainersUsePolicyInBothColumns() {
        guard #available(iOS 16.0, *) else { return }
        let runtime = ConversationPreviewData.detailsRuntime()
        let containers: [UIViewController] = [
            ChatSplitViewController(runtime: runtime),
            ContactsSplitViewController(runtime: runtime),
            ProfileSplitViewController(session: runtime.session, runtime: runtime),
        ]
        for container in containers {
            container.loadViewIfNeeded()
            let split = container.children.compactMap { $0 as? UISplitViewController }.first
            #expect(split != nil)
            for column in [UISplitViewController.Column.primary, .secondary] {
                let navigation = split?.viewController(for: column) as? AppNavigationController
                #expect(navigation != nil)
                #expect(navigation?.viewControllers.first?.hidesBottomBarWhenPushed == false)
                let detail = UIViewController()
                navigation?.pushViewController(detail, animated: false)
                #expect(detail.hidesBottomBarWhenPushed)
                navigation?.popToRootViewController(animated: false)
                #expect(navigation?.topViewController?.hidesBottomBarWhenPushed == false)
            }
        }
    }

    @Test func nestedContainerUpdatesNativeTabBarAndIgnoresInactiveTabs() throws {
        guard #available(iOS 18.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let root = UIViewController()
        let navigation = AppNavigationController(rootViewController: root)
        let container = UIViewController()
        container.addChild(navigation)
        container.view.addSubview(navigation.view)
        navigation.view.frame = container.view.bounds
        navigation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigation.didMove(toParent: container)
        let other = AppNavigationController(rootViewController: UIViewController())
        let tabs = UITabBarController()
        tabs.viewControllers = [container, other]
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #expect(!tabs.isTabBarHidden)

        other.pushViewController(UIViewController(), animated: false)
        #expect(!tabs.isTabBarHidden)
        navigation.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        #expect(tabs.isTabBarHidden)
        navigation.popToRootViewController(animated: false)
        window.layoutIfNeeded()
        #expect(!tabs.isTabBarHidden)
    }

    @Test func collapsedSplitDetailHonorsOuterNavigationStack() async throws {
        guard #available(iOS 18.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let runtime = ConversationPreviewData.detailsRuntime()
        let chat = ChatSplitViewController(runtime: runtime)
        let tabs = UITabBarController()
        tabs.viewControllers = [chat]
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        chat.open(ConversationPreviewData.detailsConversation())
        try await Task.sleep(nanoseconds: 700_000_000)
        window.layoutIfNeeded()
        func navigations(in controller: UIViewController) -> [AppNavigationController] {
            let current = (controller as? AppNavigationController).map { [$0] } ?? []
            return current + controller.children.flatMap { navigations(in: $0) }
        }
        let detail = try #require(navigations(in: tabs).first {
            $0.viewControllers.first is LiveConversationViewController
        })
        #expect(detail.viewControllers.count == 1)
        #expect(detail.topViewController?.hidesBottomBarWhenPushed == false)
        #expect(tabs.isTabBarHidden)
        detail.pushViewController(UIViewController(), animated: false)
        window.layoutIfNeeded()
        #expect(tabs.isTabBarHidden)
        detail.popToRootViewController(animated: false)
        window.layoutIfNeeded()
        #expect(tabs.isTabBarHidden)
        let primary = try #require(navigations(in: tabs).first {
            $0.viewControllers.first is ConversationListViewController
        })
        primary.popToRootViewController(animated: false)
        window.layoutIfNeeded()
        #expect(!tabs.isTabBarHidden)
    }
}
