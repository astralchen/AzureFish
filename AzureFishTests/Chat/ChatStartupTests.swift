import AzureFishAPI
import AzureFishChat
import Foundation
import Testing
import UIKit
@testable import AzureFish

private actor StartupTestSession: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

@Suite("启动会话列表", .serialized)
@MainActor
struct ChatStartupTests {
    @Test func startupDoesNotOpenDetailOrClearUnread() async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 21, count: 32), environment: "startup-test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 22, count: 32), environment: "startup-test", userID: user)
        let environment = try APIEnvironment(identifier: "startup-test", baseURL: URL(string: "https://example.invalid")!)
        let engine = ChatEngine(store: store, session: APISessionManager(api: AccountAPI(environment: environment), store: StartupTestSession()))
        let conversation = ConversationPreviewData.detailsConversation()
        try await store.save(conversation)
        try await store.saveDraft(.init(text: "启动时保留的草稿"), conversation: conversation.id)
        try await store.setManuallyUnread(true, conversation: conversation.id)
        let runtime = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: [conversation], pageLeaseRoot: root)
        let chat = ChatSplitViewController(runtime: runtime)
        chat.loadViewIfNeeded()
        let split = try #require(chat.children.compactMap { $0 as? UISplitViewController }.first)
        let placeholder = try #require(split.viewController(for: .secondary))
        for _ in 0..<3 {
            try await runtime.refreshListStates()
            // 允许旧实现异步读取选择并尝试导航，防止仅检查同步首帧。
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(split.viewController(for: .secondary) === placeholder)
            #expect(chat.splitViewController(split, topColumnForCollapsingToProposedTopColumn: .secondary) == .primary)
        }
        #expect(runtime.listStates[conversation.id]?.manuallyUnread == true)
        chat.open(conversation)
        let detail = try #require(split.viewController(for: .secondary))
        #expect(detail !== placeholder)
        runtime.publish()
        #expect(split.viewController(for: .secondary) === detail)
        #expect(chat.splitViewController(split, topColumnForCollapsingToProposedTopColumn: .primary) == .secondary)

        let restarted = ChatSplitViewController(runtime: runtime)
        restarted.loadViewIfNeeded()
        let restartedSplit = try #require(restarted.children.compactMap { $0 as? UISplitViewController }.first)
        try await runtime.refreshListStates()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(restarted.splitViewController(restartedSplit, topColumnForCollapsingToProposedTopColumn: .secondary) == .primary)
    }

    @Test func signedInRootStartsOnChatList() throws {
        guard #available(iOS 16.0, *) else { return }
        let root = AccountRootViewController(session: ConversationPreviewData.detailsRuntime().session)
        root.loadViewIfNeeded()
        let tabs = try #require(root.children.compactMap { $0 as? UITabBarController }.first)
        #expect(tabs.selectedIndex == 0)
        #expect(tabs.selectedViewController is ChatSplitViewController)
    }
}
