import AzureFishChat
import QuickLayoutKit
import Testing
import UIKit

@testable import AzureFish

@MainActor
@Suite("全屏聊天列表与空状态", .serialized)
struct ChatListStateTests {
    @Test func emptyRequiresCompletedSnapshotAndSearchIsSeparate() {
        for sync: ChatSynchronizationState in [.idle, .syncing, .synced] {
            #expect(ChatListContentState.resolve(hasSnapshot: false, synchronization: sync,
                storageFailure: false, totalCount: 0, matchCount: 0, searching: false) == .loading)
        }
        #expect(ChatListContentState.resolve(hasSnapshot: false, synchronization: .failed,
            storageFailure: false, totalCount: 0, matchCount: 0, searching: false) == .failed)
        #expect(ChatListContentState.resolve(hasSnapshot: true, synchronization: .failed,
            storageFailure: false, totalCount: 0, matchCount: 0, searching: false) == .empty)
        #expect(ChatListContentState.resolve(hasSnapshot: true, synchronization: .synced,
            storageFailure: false, totalCount: 4, matchCount: 0, searching: true) == .noResults)
        #expect(ChatListContentState.resolve(hasSnapshot: true, synchronization: .failed,
            storageFailure: false, totalCount: 4, matchCount: 4, searching: false) == .content)
        #expect(ChatListContentState.resolve(hasSnapshot: false, synchronization: .idle,
            storageFailure: true, totalCount: 0, matchCount: 0, searching: false) == .storageFailure)
    }

    @Test func collectionFillsContainerAndEmptyIsNotARow() {
        let controller = ConversationListViewController(runtime: ChatRuntime(session: .configured()))
        controller.loadViewIfNeeded()
        for width: CGFloat in [320, 390, 700] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            controller.additionalSafeAreaInsets = UIEdgeInsets(top: 100, left: 0, bottom: 80, right: 0)
            controller.setNeedsQuickLayout()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            #expect(controller.list.frame == controller.view.bounds)
            #expect(controller.list.contentInsetAdjustmentBehavior == .automatic)
            #expect(controller.list.contentInset == .zero)
            #expect(controller.rows.isEmpty)
            #expect(controller.list.backgroundView != nil)
        }
    }

    @Test func placeholderCentersInViewportAndSupportsLargeRTLText() {
        let view = ChatListStateView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.viewportInsets = UIEdgeInsets(top: 210, left: 0, bottom: 84, right: 0)
        view.content.configure(.empty)
        view.layoutIfNeeded()
        let frame = view.content.convert(view.content.bounds, to: view)
        #expect(abs(frame.midY - (210 + (844 - 210 - 84) / 2)) < 1)
        #expect(frame.minX == 0 && frame.width == 390)
        var retries = 0
        view.content.retry = { retries += 1 }
        view.content.configure(.failed)
        view.semanticContentAttribute = .forceRightToLeft
        view.content.titleLabel.font = .systemFont(ofSize: 42)
        view.content.detailLabel.font = .systemFont(ofSize: 34)
        view.content.titleLabel.text = "تعذّر تحميل المحادثات"
        view.content.detailLabel.text = "تحقّق من اتصالك وحاول مرة أخرى."
        view.frame.size = CGSize(width: 320, height: 350)
        view.viewportInsets = UIEdgeInsets(top: 120, left: 0, bottom: 100, right: 0)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        view.content.layoutIfNeeded()
        #expect(view.content.bounds.height > 130)
        #expect(view.content.retryButton.bounds.height >= 44)
        let label = view.content.titleLabel.convert(view.content.titleLabel.bounds, to: view.content)
        #expect(label.minX >= 24 && label.maxX <= 296)
        view.content.retryButton.sendActions(for: .touchUpInside)
        #expect(retries == 1)
        view.content.configure(.empty)
        #expect(view.content.retryButton.isHidden)
    }

    @Test func systemBarsKeyboardAndFirstLastRowsUseOneInset() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        let controller = ConversationListViewController(runtime: ChatRuntime(session: .configured()))
        let navigation = UINavigationController(rootViewController: controller)
        navigation.tabBarItem = UITabBarItem(title: Localization.text("account.design.chat"),
            image: UIImage(systemName: "bubble.left.and.bubble.right"), tag: 0)
        let contacts = UIViewController(), me = UIViewController()
        contacts.tabBarItem = UITabBarItem(title: Localization.text("chat.live.contacts"), image: UIImage(systemName: "person.2"), tag: 1)
        me.tabBarItem = UITabBarItem(title: Localization.text("account.design.me"), image: UIImage(systemName: "person.crop.circle"), tag: 2)
        let tabs = UITabBarController()
        tabs.viewControllers = [navigation, contacts, me]
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.view.layoutIfNeeded()
        let list = controller.list
        #expect(list.frame == controller.view.bounds)
        #expect(list.contentInset == .zero)
        #expect(list.adjustedContentInset.top > 0 && list.adjustedContentInset.bottom > 0)
        let state = try #require(list.backgroundView as? ChatListStateView)
        state.content.configure(.empty)
        state.setNeedsLayout()
        state.layoutIfNeeded()
        state.content.layoutIfNeeded()
        // 保存组件宿主截图，只使用确定性空状态，不连接服务或读取账号库。
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            window.overrideUserInterfaceStyle = style
            // 等待系统玻璃控件完成外观过渡后取图，避免截到尚未合成的操作区域。
            try await Task.sleep(nanoseconds: 500_000_000)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-list-\(name).png")
            try image.pngData()?.write(to: url)
            print("CHAT_LIST_CAPTURE \(url.path)")
        }
        let keyboard = CGRect(x: 0, y: window.bounds.height - 300, width: window.bounds.width, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboard, to: window.screen.coordinateSpace))])
        state.layoutIfNeeded()
        #expect(abs(list.adjustedContentInset.bottom - 300) < 1)
        let contentFrame = state.content.convert(state.content.bounds, to: window)
        #expect(contentFrame.maxY <= keyboard.minY)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(list.contentInset.bottom == 0)

        list.backgroundView = nil
        controller.rows = (0..<30).map { LiveChatRow(id: "fixture-\($0)", title: "聊天 \($0)") }
        try await Task.sleep(nanoseconds: 200_000_000)
        list.layoutIfNeeded()
        #expect(list.numberOfItems(inSection: 0) == 30)
        list.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        list.layoutIfNeeded()
        let first = try #require(list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        #expect(first.frame.minY >= list.bounds.minY + list.adjustedContentInset.top - 1)
        list.scrollToItem(at: IndexPath(item: 29, section: 0), at: .bottom, animated: false)
        list.layoutIfNeeded()
        let last = try #require(list.layoutAttributesForItem(at: IndexPath(item: 29, section: 0)))
        #expect(last.frame.maxY <= list.bounds.maxY - list.adjustedContentInset.bottom + 1)
    }
}
