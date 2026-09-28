import AzureFishAPI
import AzureFishChat
import AzureFishNetwork
import Foundation
import Testing
import UIKit
@testable import AzureFish

@Suite("原版聊天真实数据适配")
@MainActor
struct ChatOriginalUIIntegrationTests {
    @Test func encryptedDraftRoundTripPreservesFormattingAndResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = UUID()
        let database = try ChatStore(url: root.appendingPathComponent("store.sqlite"), key: Data(repeating: 1, count: 32), environment: "test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 2, count: 32), environment: "test", userID: user)
        let adapter = AccountChatDraftStore(store: database, media: media)
        let files = PageAttachmentStore(parentDirectory: root)
        let url = files.makeFileURL(prefix: "test", pathExtension: "txt")
        try Data("secret-attachment".utf8).write(to: url)
        let file = FileAttachment(id: UUID(), fileURL: url, displayName: "test.txt", typeIdentifier: "public.plain-text", byteCount: 17)
        let rich = MessageText(runs: [.init("保留格式 العربية 👩🏽‍💻", style: [.bold, .underline])])
        var snapshot = ChatDraftSnapshot(conversationID: "one")
        snapshot.segments = [.richText(rich), .attachment(file.id)]
        snapshot.documents = [.file(file)]
        try await adapter.save(snapshot).value
        let persisted: ChatDraftSnapshot = try #require(await database.meta("rich-draft:one"))
        #expect(persisted.localFileURLs.allSatisfy { $0.scheme == "azurefish-media" })
        let second = PageAttachmentStore(parentDirectory: root)
        let restored = try await adapter.load(conversationID: "one", into: second.directoryURL).value
        #expect(restored.snapshot?.segments == snapshot.segments)
        let resource = try #require(restored.snapshot?.documents.first?.localFileURLs.first)
        #expect(try Data(contentsOf: resource) == Data("secret-attachment".utf8))
        #expect(try await adapter.load(conversationID: "other", into: second.directoryURL).value.snapshot == nil)
        try await adapter.remove(conversationID: "one").value
        #expect(try await adapter.load(conversationID: "one", into: second.directoryURL).value.snapshot?.isEmpty == true)
        files.removeAll(); second.removeAll()
        try await database.close()
        #expect(!String(decoding: try Data(contentsOf: root.appendingPathComponent("store.sqlite")), as: UTF8.self).contains(rich.text))
    }

    @Test func realRouteUsesOriginalUIAndKeepsIdentityAfterAcknowledgement() async throws {
        guard #available(iOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let credentials = try sampleCredentials()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try APIEnvironment.localTesting(), transport: transport)),
            store: credentialStore, repository: UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID))
        await session.restore()
        await transport.setOffline(true)
        let database = try ChatStore(url: root.appendingPathComponent("chat.sqlite"), key: Data(repeating: 3, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 4, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let conversationID = UUID().uuidString.lowercased(), user = credentials.userID.uuidString.lowercased()
        let json: [String: Any] = ["id": conversationID, "kind": "group", "title": "真实会话导航", "ownerID": user,
            "members": [["id": user, "active": true, "intervals": [["joined": 1, "left": 0]], "profile": ["id": user, "nickname": "测试成员", "version": 1]]],
            "revision": 1, "boundaryRevision": 1, "latest": 0, "closed": false,
            "readState": ["read": 0, "delivered": 0, "unread": 0, "through": 0, "revision": 1]]
        let conversation = try JSONDecoder().decode(ChatConversation.self, from: JSONSerialization.data(withJSONObject: json))
        let engine = ChatEngine(store: database, session: try #require(session.sessionManager))
        let runtime = ChatRuntime(session: session, engine: engine, media: media, conversations: [conversation], pageLeaseRoot: root)
        let page = try #require(ConversationPageFactory.make(runtime: runtime, conversation: conversation) as? ChatViewController)
        let live = try #require(page.session as? LiveChatSession)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        page.loadViewIfNeeded()
        if let task = page.draftRestoreTask { await task.value }
        #expect(page.navigationItem.titleView == nil)
        #expect(page.title == "真实会话导航")
        #expect(page.navigationItem.rightBarButtonItem != nil)
        let rich = MessageText(runs: [.init("真实富文本", style: .bold)])
        let accepted = await withCheckedContinuation { continuation in
            live.send([.richText(rich)]) { continuation.resume(returning: $0) }
        }
        #expect(accepted)
        let outgoing = try #require(await database.pending().first?.outgoing)
        for _ in 0..<100 where page.viewModel.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let before = try #require(page.viewModel.messages.first?.id)
        #expect(page.viewModel.messages.first?.content == .richText(rich))
        let messageJSON: [String: Any] = ["id": outgoing.id.uuidString.lowercased(), "conversationID": conversationID,
            "clientID": outgoing.clientID.uuidString.lowercased(), "serverID": UUID().uuidString, "senderID": user,
            "deviceID": credentials.deviceID.uuidString.lowercased(), "sequence": 1, "createdAt": 1_800_000_000_000,
            "revision": 1, "kind": "text", "schemaVersion": 1, "text": rich.text,
            "textRuns": [["text": rich.text, "style": 1]], "revoked": false,
            "receipt": ["expected": 1, "delivered": 1, "read": 0, "revision": 1], "assets": []]
        let confirmed = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: messageJSON))
        try await database.save(confirmed)
        live.refresh()
        await live.reloadTask?.value
        #expect(page.viewModel.messages.count == 1)
        #expect(page.viewModel.messages.first?.id == before)
        #expect(page.viewModel.messages.first?.deliveryState == .delivered)
        #expect(page.viewModel.pendingReplies.isEmpty)
        var noticeJSON = messageJSON
        noticeJSON["id"] = UUID().uuidString.lowercased()
        noticeJSON["senderID"] = ""
        noticeJSON["deviceID"] = ""
        noticeJSON["clientID"] = ""
        noticeJSON["sequence"] = 2
        noticeJSON["kind"] = "system"
        noticeJSON["text"] = ""
        noticeJSON["textRuns"] = []
        noticeJSON["systemEvent"] = ["kind": "friendship_accepted", "relationshipID": "fictional-pair",
            "relationshipRevision": 2, "requesterID": user, "accepterID": "fictional-peer"]
        let notice = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: noticeJSON))
        try await database.save(notice)
        live.refresh()
        await live.reloadTask?.value
        let presentedNotice = try #require(page.viewModel.messages.last)
        #expect(presentedNotice.systemNotice == Localization.text("chat.system.friendshipAcceptedOther"))
        #expect(presentedNotice.deliveryState == nil && presentedNotice.statusText == nil && !presentedNotice.canRevoke)
        #expect(page.viewModel.makeState().timeline.contains { item in
            if case .notice(let notice) = item.content { return notice.messageID == presentedNotice.id && notice.canDelete }
            return false
        })
        page.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        for (name, style, direction) in [("light", UIUserInterfaceStyle.light, UIUserInterfaceLayoutDirection.leftToRight),
                                         ("dark-rtl", .dark, .rightToLeft)] {
            window.overrideUserInterfaceStyle = style
            page.reloadLayoutDirection(direction)
            page.layoutChatContent()
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Testing.Attachment.record(image, named: "original-live-chat-" + name + ".png")
        }
        live.stop(); page.attachmentStore.removeAll()
        await engine.stop(); try await database.close()
    }

    @Test func failedSendKeepsOriginalComposerDraft() async throws {
        guard #available(iOS 26.0, *) else { return }
        let page = ChatViewController(viewModel: ChatViewModel())
        let session = RecordingSession()
        page.session = session
        page.loadViewIfNeeded()
        page.composerView.textView.text = "保留待发文字"
        page.composerView.textViewDidChange(page.composerView.textView)
        let accepted = page.composerView.actionRequested?(.sendText("保留待发文字"))
        #expect(accepted == false)
        #expect(page.isSubmittingComposition)
        #expect(session.sent == [.userText("保留待发文字")])
        session.completion?(false)
        #expect(page.composerView.textView.text == "保留待发文字")
        #expect(page.viewModel.messages.isEmpty)
        #expect(!page.isSubmittingComposition)
        _ = page.composerView.actionRequested?(.sendText("保留待发文字"))
        session.completion?(true)
        #expect(page.composerView.textView.text.isEmpty)
        #expect(page.viewModel.pendingReplies.isEmpty)
        #expect(page.viewModel.messages.isEmpty)
        page.attachmentStore.removeAll()
    }
}

@available(iOS 26.0, *)
@MainActor
private final class RecordingSession: ChatSessionProviding {
    var sent: [MessageContent] = []
    var completion: ((Bool) -> Void)?
    func start(in controller: ChatViewController) {}
    func stop() {}
    func refresh() {}
    func loadHistory() {}
    func send(_ contents: [MessageContent], completion: @escaping (Bool) -> Void) { sent = contents; self.completion = completion }
    func retry(_ messageID: Int) {}
    func delete(_ messageID: Int) {}
    func revoke(_ messageID: Int) {}
    func reedit(_ messageID: Int) {}
    func viewportChanged() {}
    func didTranscribe(_ text: String, messageID: Int, attachmentID: UUID) {}
}
