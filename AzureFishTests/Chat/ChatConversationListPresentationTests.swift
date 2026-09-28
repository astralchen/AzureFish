import AppLocalization
import AzureFishAPI
import AzureFishChat
import Foundation
import Testing
import UIKit
@testable import AzureFish

private actor ListTestSession: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

@MainActor
@Suite("会话列表筛选、置顶样式与跨窗口提醒", .serialized)
struct ChatConversationListPresentationTests {
    @Test func listActionsAndSharedState() async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 41, count: 32), environment: "list-ui", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 42, count: 32), environment: "list-ui", userID: user)
        let manager = APISessionManager(api: AccountAPI(environment: try APIEnvironment(identifier: "list-ui", baseURL: URL(string: "https://example.invalid")!)), store: ListTestSession())
        let group = ConversationPreviewData.detailsConversation()
        var direct = ConversationPreviewData.detailsConversation(group: false)
        direct.readState.unread = 12
        var empty = direct; empty.id = "empty-list"; empty.latestMessage = nil; empty.latest = 0
        empty.readState.unread = 0
        for value in [group, direct, empty] { try await store.save(value) }
        for id in [group.id, direct.id] {
            try await store.enqueueComposition([.message(.init(conversationID: id, deviceID: UUID(), kind: "text", text: "测试", assets: []))], conversation: id)
        }
        let runtime = ChatRuntime(session: preview.session, engine: ChatEngine(store: store, session: manager), media: media, conversations: [group, direct, empty], pageLeaseRoot: root)
        let other = ChatRuntime(session: preview.session, engine: ChatEngine(store: store, session: manager), media: media, conversations: [group, direct, empty], pageLeaseRoot: root)
        try await runtime.refreshListStates()
        try await runtime.setPreference(.init(isPinned: true), conversation: group.id)
        #expect(runtime.visibleSortedConversations.map(\.id) == [group.id, direct.id])
        let list = ConversationListViewController(runtime: runtime)
        list.loadViewIfNeeded()
        #expect(list.rows.count == 2)
        #expect(list.rows.first?.isPinned == true)
        #expect(list.rows.first?.markers.contains("pin.fill") == false)
        #expect(list.rows.first { $0.id == direct.id }?.badge == "12")
        let order = runtime.visibleSortedConversations.map(\.id)
        let drafts = try #require(runtime.originalDraftStore)
        var snapshot = ChatDraftSnapshot(conversationID: direct.id)
        snapshot.segments = [.text("明天见")]
        try await drafts.save(snapshot).value
        #expect(other.draftPreviews[direct.id]?.text == "明天见")
        #expect(list.rows.first { $0.id == direct.id }?.isDraft == true)
        #expect(list.rows.first { $0.id == direct.id }?.subtitle.contains("明天见") == true)
        #expect(runtime.visibleSortedConversations.map(\.id) == order)
        try await runtime.setPinnedConversationsCollapsed(true)
        #expect(other.pinnedConversationsCollapsed)
        #expect(list.rows.map(\.id) == [direct.id])
        #expect(list.list.backgroundView == nil)
        try await runtime.updatePreference(conversation: direct.id, isPinned: true)
        #expect(list.rows.isEmpty)
        #expect(list.list.backgroundView == nil)
        try await runtime.updatePreference(conversation: direct.id, isPinned: false)
        let search = try #require(list.navigationItem.searchController)
        search.searchBar.text = runtime.title(group)
        list.updateSearchResults(for: search)
        #expect(list.rows.map(\.id) == [group.id])
        #expect(runtime.pinnedConversationsCollapsed)
        search.searchBar.text = ""
        list.updateSearchResults(for: search)
        #expect(list.rows.map(\.id) == [direct.id])
        try await runtime.setPinnedConversationsCollapsed(false)
        #expect(list.rows.map(\.id) == order)
        try await drafts.remove(conversationID: direct.id).value
        #expect(other.draftPreviews[direct.id] == nil)
        #expect(list.rows.first { $0.id == direct.id }?.isDraft == false)
        try await runtime.markConversationUnread(direct.id)
        #expect(list.rows.first { $0.id == direct.id }?.badge == "12")
        #expect(list.rows.first { $0.id == direct.id }?.manuallyUnread == true)
        let actions = try #require(list.trailingActions(for: group.id))
        #expect(actions.actions.count == 3)
        #expect(!actions.performsFirstActionWithFullSwipe)
        try await runtime.markConversationUnread(group.id)
        #expect(other.listStates[group.id]?.manuallyUnread == true)
        #expect(list.rows.first?.manuallyUnread == true)
        runtime.enteredConversation(group.id)
        for _ in 0..<50 where runtime.listStates[group.id]?.manuallyUnread == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(other.listStates[group.id]?.manuallyUnread == false)
        try await runtime.hideConversation(group.id)
        #expect(list.rows.map(\.id) == [direct.id])
        #expect(other.visibleSortedConversations.map(\.id) == [direct.id])
        #expect(list.trailingActions(for: group.id) == nil)
        try await runtime.hideConversation(direct.id, deleting: true)
        #expect(list.rows.isEmpty)
        #expect(list.list.backgroundView is ChatListStateView)
        #expect(try await store.pending().count == 2)
        try await store.close()
        do { try await runtime.markConversationUnread(group.id); Issue.record("Closed store must fail") } catch {}
        #expect(list.rows.isEmpty)
        do { try await runtime.setPinnedConversationsCollapsed(true); Issue.record("Closed store must fail") } catch {}
        #expect(!runtime.pinnedConversationsCollapsed)
    }

    @Test func dotAndReusedRowBackground() async throws {
        guard #available(iOS 16.0, *) else { return }
        let controller = LiveChatListController(runtime: ChatRuntime(session: .configured()))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var row = LiveChatRow(id: "row", title: "聊天", isPinned: true, manuallyUnread: true)
        controller.rows = [row]
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded(); controller.list.layoutIfNeeded()
        let cell = try #require(controller.list.cellForItem(at: .init(item: 0, section: 0)) as? UICollectionViewListCell)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(cell.backgroundConfiguration?.backgroundColor?.resolvedColor(with: traits) == UIColor.secondarySystemBackground.resolvedColor(with: traits))
        }
        #expect(cell.accessibilityLabel?.contains(Localization.text("chat.details.pinned")) == true)
        let originalLocale = Localization.localizationController.currentLocale.identifier
        let followedSystem = Localization.localizationController.followsSystemLocale
        defer {
            if followedSystem { Localization.localizationController.setFollowsSystemLocale() }
            else { Localization.setLocale(identifier: originalLocale) }
        }
        for locale in ["ar", "en"] {
            Localization.setLocale(identifier: locale)
            controller.reloadLayoutDirection(Localization.currentUIKitDirection)
            controller.reloadLocalizedContent()
            // 本地化通知与 diffable 重配异步完成，不依赖机器负载下的固定 100 ms 延时。
            for _ in 0..<100 {
                controller.list.layoutIfNeeded()
                let label = controller.list.cellForItem(at: .init(item: 0, section: 0))?.accessibilityLabel ?? ""
                if label.contains(Localization.text("chat.details.pinned")),
                   label.contains(Localization.text("chat.list.manuallyUnread")) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let localized = try #require(controller.list.cellForItem(at: .init(item: 0, section: 0)))
            #expect(localized.accessibilityLabel?.contains(Localization.text("chat.details.pinned")) == true)
            #expect(localized.accessibilityLabel?.contains(Localization.text("chat.list.manuallyUnread")) == true)
            #expect(controller.rows == [row])
        }
        row.isPinned = false; row.manuallyUnread = false
        controller.rows = [row]
        try await Task.sleep(for: .milliseconds(100))
        controller.list.layoutIfNeeded()
        let reused = try #require(controller.list.cellForItem(at: .init(item: 0, section: 0)) as? UICollectionViewListCell)
        #expect(reused.backgroundConfiguration?.backgroundColor == .systemBackground)
        #expect(reused.accessibilityLabel?.contains(Localization.text("chat.details.pinned")) == false)
        let dot = UnreadCountBadgeView(text: "", dot: true)
        #expect(dot.bounds.size == CGSize(width: 10, height: 10))
        #expect(dot.textLabel.text == nil)
        if #available(iOS 17.0, *) {
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.semanticContentAttribute = .forceRightToLeft
            controller.rows = [row]
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded(); controller.list.layoutIfNeeded()
            let large = try #require(controller.list.cellForItem(at: .init(item: 0, section: 0)) as? UICollectionViewListCell)
            let content = try #require(large.contentConfiguration as? UIListContentConfiguration)
            #expect(content.image == nil)
            #expect(large.accessories.count == 2)
            #expect(controller.rows == [row])
        }
    }
}
