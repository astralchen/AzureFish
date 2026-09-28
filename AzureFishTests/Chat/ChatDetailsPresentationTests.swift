import AzureFishAPI
import AzureFishChat
import Foundation
import Testing
import UIKit
@testable import AzureFish

private actor DetailsTestSession: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

@Suite("聊天详情展示和应用内提醒", .serialized)
@MainActor
struct ChatDetailsPresentationTests {
    @Test func preferenceOrderingFailureAndBanners() async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        let user = try #require(UUID(uuidString: preview.userID))
        let database = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 19, count: 32), environment: "test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 20, count: 32), environment: "test", userID: user)
        let manager = APISessionManager(api: AccountAPI(environment: try APIEnvironment(identifier: "test", baseURL: URL(string: "https://example.invalid")!)), store: DetailsTestSession())
        let engine = ChatEngine(store: database, session: manager)
        let conversation = ConversationPreviewData.detailsConversation()
        let direct = ConversationPreviewData.detailsConversation(group: false)
        try await database.save(conversation); try await database.save(direct)
        let runtime = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: [conversation, direct], pageLeaseRoot: root)
        try await runtime.setPreference(.init(isPinned: true), conversation: direct.id)
        #expect(runtime.sortedConversations.first?.id == direct.id)
        let json: [String: Any] = ["id": "banner-test", "conversationID": conversation.id, "clientID": "c", "serverID": "s", "senderID": conversation.members[1].id,
            "deviceID": "test", "sequence": 1, "createdAt": 1_800_000_000_000, "revision": 1, "kind": "text", "schemaVersion": 1,
            "text": "仅在应用前台展示", "revoked": false, "assets": [], "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0]]
        let message = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: json))
        try await database.save(message)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view.backgroundColor = .systemBackground
        window.rootViewController = host; window.makeKeyAndVisible()
        var opened: String?
        let banners = ChatIncomingBannerCoordinator(host: host, runtime: runtime) { opened = $0.id }
        defer { banners.stop(); window.isHidden = true; previous?.makeKey() }
        banners.updateActivity()
        try await runtime.setPreference(.init(isMuted: true), conversation: conversation.id)
        runtime.incomingMessages?([message])
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty)
        try await runtime.setPreference(.init(), conversation: conversation.id)
        runtime.incomingMessages?([message])
        for _ in 0..<100 where host.view.subviews.compactMap({ $0 as? ChatIncomingBannerView }).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let banner = try #require(host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.first)
        #expect(opened == nil)
        banner.open?()
        for _ in 0..<50 where opened == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(opened == conversation.id)
        #expect(try await database.conversations().first { $0.id == conversation.id }?.readState.read == 0)
        runtime.incomingMessages?([message])
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty)
        let details = ConversationDetailsViewController(runtime: runtime, conversation: conversation)
        let navigation = UINavigationController(rootViewController: details)
        host.addChild(navigation); host.view.addSubview(navigation.view); navigation.didMove(toParent: host)
        navigation.pushViewController(ConversationMemberViewController(runtime: runtime, member: conversation.members[1]), animated: false)
        var following = message
        following.id = "banner-on-details"
        following.sequence = 2
        try await database.save(following)
        runtime.incomingMessages?([following])
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty)
        navigation.willMove(toParent: nil); navigation.view.removeFromSuperview(); navigation.removeFromParent()
        let otherRuntime = ChatRuntime(session: preview.session, engine: ChatEngine(store: database, session: manager), media: media, conversations: [conversation], pageLeaseRoot: root)
        let otherHost = UIViewController()
        let otherBanners = ChatIncomingBannerCoordinator(host: otherHost, runtime: otherRuntime) { _ in Issue.record("Inactive scene must not navigate") }
        defer { otherBanners.stop() }
        otherRuntime.incomingMessages?([following])
        for _ in 0..<100 where host.view.subviews.compactMap({ $0 as? ChatIncomingBannerView }).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty)
        #expect(otherHost.viewIfLoaded?.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty != false)
        try await runtime.setPreference(.init(isMuted: true), conversation: conversation.id)
        #expect(host.view.subviews.compactMap { $0 as? ChatIncomingBannerView }.isEmpty)
        try await database.close()
        do { try await runtime.setPreference(.init(), conversation: direct.id); Issue.record("Closed storage must fail") } catch {}
        #expect(runtime.preference(direct.id).isPinned)
    }
}
