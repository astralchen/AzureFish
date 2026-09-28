import AzureFishAPI
import AzureFishChat
import CryptoKit
import Foundation

/// 当前账号聊天运行环境；退出时停止连接、队列与明文租约，保留加密文件。
@MainActor
final class ChatRuntime {
    let session: SessionCoordinator
    private(set) var engine: ChatEngine?
    private(set) var media: ChatMediaStore?
    private(set) var transfers: ChatTransferQueue?
    private(set) var originalDraftStore: AccountChatDraftStore?
    private(set) var pageLeaseRoot: URL?
    private(set) var contacts: [ChatContact] = []
    private(set) var conversations: [ChatConversation] = []
    private(set) var online = false
    private(set) var failure: String?
    private(set) var hasSnapshot = false
    private(set) var synchronization: ChatSynchronizationState = .idle
    private var observers: [UUID: () -> Void] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var api: IMAPI? { session.sessionManager.map(IMAPI.init) }
    var userID: String { session.profile?.userID.uuidString.lowercased() ?? "" }
    init(session: SessionCoordinator) { self.session = session }
    /// 注入已打开的账号资源，供隔离集成验证使用；不启动后台同步或创建替代密钥。
    init(session: SessionCoordinator, engine: ChatEngine, media: ChatMediaStore,
         conversations: [ChatConversation], pageLeaseRoot: URL) {
        self.session = session; self.engine = engine; self.media = media
        self.conversations = conversations.sorted {
                        let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
                        return left == right ? $0.id < $1.id : left > right
                    }; self.pageLeaseRoot = pageLeaseRoot
        originalDraftStore = AccountChatDraftStore(store: engine.store, media: media)
        if let manager = session.sessionManager {
            transfers = ChatTransferQueue(store: engine.store, media: media, session: manager, engine: engine)
        }
    }
    func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }
    func remove(_ id: UUID) { observers[id] = nil }
    func publish() { observers.values.forEach { $0() } }
    func start() {
        guard task == nil, let manager = session.sessionManager, let user = session.profile?.userID
        else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let scope = manager.environment.identifier + ":" + user.uuidString.lowercased()
                let directoryName = SHA256.hash(data: Data(scope.utf8)).map {
                    String(format: "%02x", $0)
                }.joined()
                var root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("ChatAccounts/" + directoryName, isDirectory: true)
                let exists = FileManager.default.fileExists(atPath: root.path)
                @MainActor func key(_ purpose: String) throws -> Data {
                    let name = "chat." + purpose + "." + scope
                    if let value = try session.store.values.read(name) {
                        guard value.count == 32 else { throw AccountFailure.storage }
                        return value
                    }
                    guard !exists else { throw AccountFailure.storage }
                    let value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    try session.store.values.write(value, key: name)
                    return value
                }
                let databaseKey = try key("database")
                let mediaKey = try key("media")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                    ])
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let store = try ChatStore(
                    url: root.appendingPathComponent("main.sqlite"), key: databaseKey,
                    environment: manager.environment.identifier, userID: user)
                let media = try ChatMediaStore(
                    root: root.appendingPathComponent("media", isDirectory: true), key: mediaKey,
                    environment: manager.environment.identifier, userID: user)
                guard self.generation == generation else {
                    try await store.close()
                    return
                }
                let engine = ChatEngine(store: store, session: manager)
                let pages = root.appendingPathComponent("page-leases", isDirectory: true)
                if FileManager.default.fileExists(atPath: pages.path) { try FileManager.default.removeItem(at: pages) }
                try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                self.pageLeaseRoot = pages
                self.originalDraftStore = AccountChatDraftStore(store: store, media: media)
                self.engine = engine
                self.media = media
                let transfers = ChatTransferQueue(
                    store: store, media: media, session: manager, engine: engine)
                self.transfers = transfers
                await transfers.resume()
                let changes = await engine.updates()
                await engine.start()
                for await update in changes {
                    guard self.generation == generation, !Task.isCancelled else { break }
                    let contacts = try await store.contacts()
                    let conversations = try await store.conversations()
                    let hasSnapshot = try await store.checkpoint() != nil
                    guard self.generation == generation, !Task.isCancelled else { break }
                    self.online = update.online
                    self.synchronization = update.synchronization
                    self.hasSnapshot = hasSnapshot
                    self.contacts = contacts
                    self.conversations = conversations.sorted {
                        let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
                        return left == right ? $0.id < $1.id : left > right
                    }
                    self.publish()
                    if let invalidated = try? await store.mediaInvalidations() {
                        var removed = Set<UUID>()
                        for id in invalidated {
                            do { try await media.remove(id); removed.insert(id) } catch { /* 下次同步继续清理。 */ }
                        }
                        try? await store.acknowledgeMediaInvalidations(removed)
                    }
                    if update.online { await transfers.resume() }
                }
            } catch {
                guard self.generation == generation else { return }
                self.failure = "chat.live.storageFailure"
                self.publish()
            }
        }
    }
    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        let old = engine
        let media = media
        let transfers = transfers
        let pages = pageLeaseRoot
        pageLeaseRoot = nil
        originalDraftStore = nil
        engine = nil
        self.media = nil
        self.transfers = nil
        contacts = []
        conversations = []
        online = false
        hasSnapshot = false
        synchronization = .idle
        failure = nil
        publish()
        Task {
            await transfers?.stop()
            await old?.stop()
            try? await media?.clearLeases()
            if let pages { try? FileManager.default.removeItem(at: pages) }
            try? await old?.store.close()
        }
    }
    func title(_ conversation: ChatConversation) -> String {
        if conversation.kind == "group" { return conversation.title }
        let peer = conversation.members.first { $0.id != userID }?.id ?? ""
        return contacts.first { $0.peer.id == peer }?.peer.nickname
            ?? Localization.text("chat.live.privateChat")
    }
    func canSend(_ conversation: ChatConversation) -> Bool {
        let conversation = conversations.first { $0.id == conversation.id } ?? conversation
        return !conversation.closed
            && conversation.members.contains { $0.id == userID && $0.active }
            && (conversation.kind == "group"
                || contacts.contains {
                    $0.state == "friend"
                        && $0.peer.id == conversation.members.first(where: { $0.id != userID })?.id
                })
    }
    func refresh() { Task { try? await engine?.synchronize() } }
    /// 等待共享同步结束，供刷新控件结束动画；存储不可用时不创建替代数据库。
    func refreshAndWait() async { try? await engine?.synchronize() }
    func changed() { Task { await engine?.changed() } }
    deinit { task?.cancel() }
}
