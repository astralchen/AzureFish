import AzureFishAPI
import AzureFishChat
import AzureFishNetwork
import AzureFishProtocol
import Foundation
import SwiftProtobuf
import Testing
import UIKit
@testable import AzureFish

private actor ContactCacheTransport: HTTPTransport {
    let owner: UUID
    var contact: ContactRelationship
    var reads = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    init(owner: UUID) {
        self.owner = owner
        var contact = ContactRelationship()
        contact.peer.userID = UUID().uuidString.lowercased(); contact.peer.nickname = "Before"
        contact.peer.profileVersion = 1; contact.peer.avatarID = "old"
        contact.relationshipID = UUID().uuidString; contact.semanticsVersion = 2
        contact.isContact = true; contact.state = "friend"; contact.revision = 1
        self.contact = contact
    }
    func release() { let saved = held; held = []; saved.forEach { $0.resume() } }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let bytes: Data
        if request.url.path.hasSuffix("me") {
            var profile = AzureFishProtocol.UserProfile()
            profile.userID = owner.uuidString.lowercased(); profile.nickname = "Fixture"
            profile.profileVersion = 1; profile.accountName = "fixture_user"
            profile.createdAtMs = 1_800_000_000_000; profile.updatedAtMs = 1_800_000_000_000
            bytes = try profile.serializedData()
        } else if request.url.path.hasSuffix("contacts/get") {
            reads += 1
            let saved = contact
            // 故意忽略取消，验证旧资料到达时的生命周期及版本检查。
            await withCheckedContinuation { held.append($0) }
            bytes = try saved.serializedData()
        } else { throw URLError(.notConnectedToInternet) }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: bytes)
    }
}

@MainActor
@Suite("通讯录缓存与资料更新", .serialized)
struct ChatContactCacheTests {
    @Test func unchangedNotificationsKeepEmptyDirectoryLayoutAndStateTransitions() async throws {
        guard #available(iOS 16.0, *) else { return }
        for mode: ContactDirectoryController.Mode in [.contacts, .requests, .blocked] {
            let runtime = ChatRuntime(previewContacts: [])
            let controller = ContactDirectoryController(runtime: runtime, mode: mode)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = UINavigationController(rootViewController: controller)
            window.isHidden = false
            defer { window.isHidden = true }
            controller.loadViewIfNeeded()
            for _ in 0..<100 where controller.list.backgroundView == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            window.layoutIfNeeded()
            let state = try #require(controller.list.backgroundView as? ChatListStateView)
            #expect(state.content.accessibilityIdentifier == "chat.list.state.empty")
            let title = state.content.titleLabel.text
            state.layoutIfNeeded(); state.content.layoutIfNeeded()
            #expect(!state.content.layer.needsLayout())
            for _ in 0..<3 {
                runtime.publish()
                #expect(controller.list.backgroundView === state)
                #expect(state.content.titleLabel.text == title)
                #expect(!state.content.layer.needsLayout())
            }
            let search = try #require(controller.navigationItem.searchController)
            search.searchBar.text = "NoSuchContact"
            controller.updateSearchResults(for: search)
            #expect(state.content.accessibilityIdentifier == "chat.list.state.noResults")
            state.layoutIfNeeded(); state.content.layoutIfNeeded()
            runtime.publish()
            #expect(search.searchBar.text == "NoSuchContact")
            #expect(!state.content.layer.needsLayout())
            // 联系人和连接状态不变时，快照失效仍必须将提示切换为加载状态。
            runtime.stop()
            #expect(state.content.accessibilityIdentifier == "chat.list.state.loading")
            state.layoutIfNeeded(); state.content.layoutIfNeeded()
            runtime.publish()
            #expect(!state.content.layer.needsLayout())
            #expect(search.searchBar.text == "NoSuchContact")
        }
    }

    private struct Fixture {
        let root: URL
        let transport: ContactCacheTransport
        let runtime: ChatRuntime
        let engine: ChatEngine
        let contact: ChatContact
        let keys: MemorySecureValues
        func finish() async throws {
            await transport.release()
            await AccountAvatarLoader.invalidate(scope: .init(environment: engine.store.environment, user: engine.store.userID))?.value
            try await ChatRuntime.stopAccount(user: engine.store.userID, environment: engine.store.environment)
            try FileManager.default.removeItem(at: root)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = UUID(), transport = ContactCacheTransport(owner: owner), keys = MemorySecureValues()
        let base = try sampleCredentials()
        let credentials = try SessionCredentials(environmentID: base.environmentID, userID: owner,
            deviceID: UUID(), sessionID: UUID(), accessToken: base.accessToken, accessExpiresAt: base.accessExpiresAt,
            refreshToken: base.refreshToken, refreshExpiresAt: base.refreshExpiresAt, refreshGeneration: 1)
        let credentialStore = CredentialStore(values: keys, environmentID: credentials.environmentID)
        try credentialStore.save(StoredSession(credentials))
        let repository = UserRepository(root: root.appendingPathComponent("profile"), keys: keys, environment: credentials.environmentID)
        try repository.save(AccountProfile(userID: owner, accountName: "fixture_user", nickname: "Fixture", bio: "", version: 1))
        let session = SessionCoordinator(service: LiveAccountService(api: AccountAPI(environment: try .localTesting(), transport: transport)),
            store: credentialStore, repository: repository)
        await session.restore()
        try #require(session.phase == .signedIn)
        let database = try ChatStore(url: root.appendingPathComponent("db"), key: Data(repeating: 7, count: 32), environment: credentials.environmentID, userID: owner)
        let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: Data(repeating: 8, count: 32), environment: credentials.environmentID, userID: owner)
        let engine = ChatEngine(store: database, session: try #require(session.sessionManager))
        let contact = await ChatContact(transport.contact)
        let runtime = ChatRuntime(session: session, engine: engine, media: media, conversations: [], pageLeaseRoot: root.appendingPathComponent("leases"))
        return Fixture(root: root, transport: transport, runtime: runtime, engine: engine, contact: contact, keys: keys)
    }
    @Test func localDirectoryPublishesWhileNetworkIsBlockedAndOlderResponseCannotRollBackUpdates() async throws {
        let f = try await fixture()
        try await f.engine.store.save(f.contact)
        try await f.engine.store.saveCheckpoint(.init(cursor: "baseline", epoch: "fixture"))
        let first = Task { try await f.runtime.refreshContact(peer: f.contact.peer.id) }
        while await f.transport.reads == 0 { await Task.yield() }
        try await f.runtime.restoreDirectory(engine: f.engine)
        #expect(f.runtime.hasContactSnapshot && f.runtime.contacts == [f.contact])
        var newer = f.contact
        newer.revision = 3; newer.remark = "Private note"; newer.isContact = false
        newer.peer.version = 4; newer.peer.nickname = "After"; newer.peer.avatarID = "new"
        try await f.engine.store.save(newer)
        f.runtime.receivedContact(newer, engine: f.engine)
        let otherStore = try ChatStore(url: f.root.appendingPathComponent("db"), key: Data(repeating: 7, count: 32), environment: f.engine.store.environment, userID: f.engine.store.userID)
        let otherEngine = ChatEngine(store: otherStore, session: try #require(f.runtime.session.sessionManager))
        let other = ChatRuntime(session: f.runtime.session, engine: otherEngine, media: try #require(f.runtime.media),
            conversations: [], pageLeaseRoot: f.root.appendingPathComponent("other-leases"), contacts: [newer])
        var joined = false
        let second = Task { joined = true; return try await other.refreshContact(peer: f.contact.peer.id) }
        while !joined { await Task.yield() }
        await f.transport.release()
        #expect(try await first.value == newer)
        #expect(try await second.value == newer)
        #expect(await f.transport.reads == 1)
        #expect(try await f.engine.store.contacts() == [newer])
        #expect(f.runtime.avatarAsset(user: newer.peer.id, fallback: f.contact.peer) == "new")
        #expect(f.runtime.displayName(user: newer.peer.id, fallback: f.contact.peer) == "Private note")
        try await f.finish()
    }
    @Test func defaultAvatarDeletionAndRemarkChangeInvalidateDerivedPresentation() async throws {
        let f = try await fixture()
        var contact = f.contact
        contact.remark = ""; f.runtime.receivedContact(contact, engine: f.engine)
        #expect(ContactDirectoryPresentation.sections(f.runtime.contacts, query: "Before").count == 1)
        contact.peer.version += 1; contact.peer.nickname = "After"; contact.peer.avatarID = nil
        f.runtime.receivedContact(contact, engine: f.engine)
        f.runtime.receivedContact(f.contact, engine: f.engine)
        #expect(f.runtime.avatarAsset(user: contact.peer.id, fallback: f.contact.peer) == nil)
        let profile = FriendViewController(runtime: f.runtime, contact: f.contact)
        profile.loadViewIfNeeded()
        let names = profile.fields.compactMap { ($0 as? UILabel)?.text }
        #expect(names.contains("After"))
        #expect(ContactDirectoryPresentation.sections(f.runtime.contacts, query: "Before").isEmpty)
        #expect(ContactDirectoryPresentation.sections(f.runtime.contacts, query: "After").map(\.id) == ["A"])
        contact.revision += 1; contact.remark = "Zulu"
        f.runtime.receivedContact(contact, engine: f.engine)
        #expect(ContactDirectoryPresentation.sections(f.runtime.contacts, query: "").map(\.id) == ["Z"])
        contact.peer.version += 1; contact.peer.deleted = true; contact.peer.avatarID = "old"
        f.runtime.receivedContact(contact, engine: f.engine)
        #expect(f.runtime.avatarAsset(user: contact.peer.id, fallback: f.contact.peer) == nil)
        #expect(f.runtime.displayName(user: contact.peer.id) == Localization.text("account.deletedUser"))
        try await f.finish()
    }
    @Test func visibleAvatarRejectsOldDownloadAfterProfileUpdateAndResetsOnLogout() async throws {
        let f = try await fixture()
        let session = f.runtime.session, peer = try #require(UUID(uuidString: f.contact.peer.id))
        let scope = try #require(session.avatarScope)
        let cache = AccountAvatarCache(keys: f.keys, environment: scope.environment, user: scope.user)
        defer { try? cache.delete() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard; format.opaque = true
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let loader = try AccountAvatarLoader.shared(scope: scope, keys: f.keys)
        let old = AccountAvatarLoader.Resource(user: peer, asset: "old")
        let new = AccountAvatarLoader.Resource(user: peer, asset: "new")
        var release: CheckedContinuation<Data?, Never>?
        let pending = Task { try await loader.image(old) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let current = try #require(try await loader.image(new) { bytes })
        let view = AccountAvatarView()
        view.configure(session: session, user: peer, asset: "old")
        await Task.yield()
        view.configure(session: session, user: peer, asset: "new")
        #expect(view.image === current)
        release?.resume(returning: bytes)
        _ = try await pending.value
        await Task.yield()
        #expect(view.image === current)
        view.configure(session: session, user: peer, asset: nil)
        #expect(view.image !== current)
        view.configure(session: session, user: peer, asset: "new")
        #expect(view.image === current)
        try await session.logout(localOnly: true)
        #expect(view.image !== current && loader.memoryCost == 0)
        #expect(try cache.load(user: peer, asset: "old") == bytes)
        #expect(try cache.load(user: peer, asset: "new") == bytes)
        try await f.finish()
    }
    @Test func unrelatedUpdatesReuseVisibleCellAvatarAndPreserveSearch() async throws {
        let f = try await fixture()
        f.runtime.receivedContact(f.contact, engine: f.engine)
        let controller = ContactsViewController(runtime: f.runtime)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<100 where controller.list.visibleCells.compactMap({ $0 as? ContactDirectoryCell }).isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
            window.layoutIfNeeded()
        }
        let cell = try #require(controller.list.visibleCells.compactMap { $0 as? ContactDirectoryCell }.first)
        let avatar = cell.avatar
        let image = avatar.image
        let offset = controller.list.contentOffset
        for _ in 0..<3 {
            f.runtime.publish()
            try await Task.sleep(nanoseconds: 30_000_000)
            window.layoutIfNeeded()
            #expect(controller.list.visibleCells.contains { $0 === cell })
            #expect(cell.avatar === avatar && avatar.image === image)
            #expect(controller.list.contentOffset == offset)
        }
        let search = try #require(controller.navigationItem.searchController)
        search.searchBar.text = "Before"
        controller.updateSearchResults(for: search)
        var updated = f.contact
        updated.peer.version += 1; updated.peer.nickname = "After"
        f.runtime.receivedContact(updated, engine: f.engine)
        #expect(search.searchBar.text == "Before")
        for _ in 0..<100 where controller.list.visibleCells.contains(where: { $0 is ContactDirectoryCell }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!controller.list.visibleCells.contains { $0 is ContactDirectoryCell })
        #expect(controller.list.backgroundView != nil)
        try await f.finish()
    }
    @Test func stopRejectsDelayedContactAndEmptyCacheDoesNotPretendSyncCompleted() async throws {
        let f = try await fixture()
        try await f.runtime.restoreDirectory(engine: f.engine)
        #expect(f.runtime.contacts.isEmpty && !f.runtime.hasContactSnapshot)
        let request = Task { try await f.runtime.refreshContact(peer: f.contact.peer.id) }
        while await f.transport.reads == 0 { await Task.yield() }
        f.runtime.stop()
        await f.transport.release()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(f.runtime.contacts.isEmpty)
        try await f.finish()
    }
}
