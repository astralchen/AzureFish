import AzureFishAPI
import AzureFishChat
import AzureFishNetwork
import AzureFishProtocol
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

private actor DirectConversationTestSession: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

private actor DirectResolutionTransport: HTTPTransport {
    var operations: [String] = []
    var fail = true
    let result: IMConversation
    init(owner: String, peer: String) {
        var result = IMConversation()
        result.conversationID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        result.kind = "direct"; result.serverRevision = 1; result.boundaryRevision = 1
        result.members = [owner, peer].map { id in
            var member = IMMember(); member.userID = id; member.active = true
            member.profile.userID = id; member.profile.nickname = "Fixture"
            return member
        }
        self.result = result
    }
    func allowResolution() { fail = false }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url.path.hasSuffix("conversations/resolve") else { throw URLError(.notConnectedToInternet) }
        let input = try IMResolveRequest(serializedBytes: #require(request.body))
        operations.append(input.operationID)
        if fail { throw URLError(.networkConnectionLost) }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try result.serializedData())
    }
}

@Suite("联系人打开本地私聊", .serialized)
@MainActor
struct ChatDirectConversationTests {
    @Test func emptyPageDefersResolutionUntilSendAndRetryKeepsDraftAndOperation() async throws {
        guard #available(iOS 26.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try sampleCredentials()
        let contact = ConversationPreviewData.contact
        let transport = DirectResolutionTransport(owner: credentials.userID.uuidString.lowercased(), peer: contact.peer.id)
        let keys = MemorySecureValues()
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)),
            store: credentialStore, repository: UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID))
        let manager = try #require(session.sessionManager)
        try await manager.restoreLocal()
        session.installDebugProfile()
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 33, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 34, count: 32), environment: credentials.environmentID, userID: credentials.userID)
        let runtime = ChatRuntime(session: session, engine: ChatEngine(store: store, session: manager), media: media, conversations: [], pageLeaseRoot: root, contacts: [contact])
        let local = try await runtime.directConversation(for: contact)
        try await store.saveDraft(.init(text: "首次发送保留输入"), conversation: local.id)
        let controller = try #require(ConversationPageFactory.make(runtime: runtime, conversation: local) as? ChatViewController)
        controller.loadViewIfNeeded()
        let live = try #require(controller.session as? LiveChatSession)
        defer { live.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await transport.operations.isEmpty)
        #expect(try await store.conversations().isEmpty)
        var accepted: Bool?
        live.send([.userText("首次发送保留输入")]) { accepted = $0 }
        for _ in 0..<100 where accepted == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(accepted == false)
        #expect(try await store.draft(local.id).text == "首次发送保留输入")
        // HTTPClient 对幂等请求可自动重试；所有尝试必须复用同一个操作 ID。
        let failedAttempts = await transport.operations.count
        #expect(failedAttempts > 0)
        await transport.allowResolution()
        accepted = nil
        live.send([.userText("首次发送保留输入")]) { accepted = $0 }
        for _ in 0..<100 where accepted == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(accepted == true)
        #expect(await transport.operations.count > failedAttempts)
        #expect(await Set(transport.operations).count == 1)
        let pending = try await store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.outgoing.conversationID == "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
        #expect(try await store.draft(local.id).text.isEmpty)
    }

    @Test(arguments: [false, true])
    func offlineOpensExistingDirectConversation(snapshotLoaded: Bool) async throws {
        guard #available(iOS 16.0, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = ConversationPreviewData.detailsRuntime()
        preview.session.installDebugProfile(offline: true)
        let user = try #require(UUID(uuidString: preview.userID))
        let store = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 31, count: 32), environment: "direct-test", userID: user)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 32, count: 32), environment: "direct-test", userID: user)
        let environment = try APIEnvironment(identifier: "direct-test", baseURL: URL(string: "https://example.invalid")!)
        let engine = ChatEngine(store: store, session: APISessionManager(api: AccountAPI(environment: environment), store: DirectConversationTestSession()))
        let direct = ConversationPreviewData.detailsConversation(group: false)
        let group = ConversationPreviewData.detailsConversation()
        try await store.save(group)
        try await store.save(direct)
        let runtime = ChatRuntime(session: preview.session, engine: engine, media: media,
                                  conversations: snapshotLoaded ? [group, direct] : [group], pageLeaseRoot: root)
        #expect(runtime.api == nil)
        var contact = ConversationPreviewData.contact
        contact.peer = direct.members[1].profile
        let resolved = try await runtime.directConversation(for: contact)
        #expect(resolved.id == direct.id)
        #expect(!runtime.canSend(resolved))
        // 同群成员不能误当成私聊；离线也打开独立空页面，不创建权威会话。
        contact.peer = group.members[2].profile
        let empty = try await runtime.directConversation(for: contact)
        #expect(ChatStore.localDirectPeer(empty.id) == contact.peer.id)
        #expect(try await store.conversations().count == 2)
        try await store.saveDraft(.init(text: "未发送的草稿"), conversation: empty.id)
        await #expect(throws: AccountFailure.offline) {
            try await runtime.resolveDirectConversationForSending(empty)
        }
        #expect(try await store.draft(empty.id).text == "未发送的草稿")
        let firstOperation = try await store.directResolutionOperation(empty.id)
        #expect(try await store.directResolutionOperation(empty.id) == firstOperation)

        // 服务端会话可能由同步先到达；发送时迁移到它，并重定向仍打开页面的迟到保存。
        var authoritative = empty
        authoritative.id = "resolved-direct"; authoritative.revision = 1
        try await store.save(authoritative)
        let drafts = try #require(runtime.originalDraftStore)
        var snapshot = ChatDraftSnapshot(conversationID: empty.id)
        snapshot.segments = [.text("富文本草稿")]
        try await drafts.save(snapshot).value
        try await store.saveDraft(.init(text: "另一窗口的输入"), conversation: authoritative.id)
        await #expect(throws: ChatStoreError.draftChanged) {
            try await runtime.resolveDirectConversationForSending(empty)
        }
        #expect(try await store.draft(empty.id).text == "富文本草稿")
        #expect(try await store.draft(authoritative.id).text == "另一窗口的输入")
        #expect(try await store.canonicalDraftConversation(empty.id) == empty.id)
        try await store.saveDraft(.init(), conversation: authoritative.id)
        let bound = try await runtime.resolveDirectConversationForSending(empty)
        #expect(bound.id == authoritative.id)
        #expect(try await store.canonicalDraftConversation(empty.id) == bound.id)
        snapshot.segments = [.text("迁移后的输入")]
        try await drafts.save(snapshot).value
        let migrated: ChatDraftSnapshot? = try await store.meta("rich-draft:" + bound.id)
        #expect(migrated?.conversationID == bound.id)
        #expect(try await store.draft(bound.id).text == "迁移后的输入")
        let loaded = try await drafts.load(conversationID: empty.id, into: root).value
        #expect(loaded.snapshot?.conversationID == empty.id)
        #expect(try await runtime.directConversation(for: contact).id == bound.id)
    }
}
