import AzureFishAPI
import AzureFishChat
import CryptoKit
import Foundation

/// 当前账号聊天运行环境；退出时停止连接、队列与明文租约，保留加密文件。
@MainActor
final class ChatRuntime {
    private final class WeakRuntime {
        weak var value: ChatRuntime?
        init(_ value: ChatRuntime) { self.value = value }
    }
    private static var instances: [WeakRuntime] = []
    private func registerInstance() {
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakRuntime(self))
    }
    let session: SessionCoordinator
    private(set) var engine: ChatEngine?
    private(set) var media: ChatMediaStore?
    private(set) var transfers: ChatTransferQueue?
    private(set) var originalDraftStore: AccountChatDraftStore?
    private(set) var pageLeaseRoot: URL?
    private(set) var contacts: [ChatContact] = [] { didSet { rebuildProfileIndex() } }
    private(set) var conversations: [ChatConversation] = [] { didSet { rebuildProfileIndex() } }
    private var profileIndex: [String: ChatUser] = [:]
    private func rebuildProfileIndex() {
        var values: [String: ChatUser] = [:]
        for profile in contacts.map(\.peer) + conversations.flatMap(\.members).map(\.profile) {
            if profile.version >= (values[profile.id]?.version ?? -1) { values[profile.id] = profile }
        }
        profileIndex = values
    }
    private(set) var online = false
    private(set) var failure: String?
    private(set) var hasSnapshot = false
    private(set) var synchronization: ChatSynchronizationState = .idle
    private(set) var preferences: [String: ConversationLocalPreferences] = [:]
    private(set) var listStates: [String: ConversationListState] = [:]
    private(set) var draftPreviews: [String: ConversationDraftPreview] = [:]
    private(set) var pinnedConversationsCollapsed = false
    private var listRefresh = UUID()
    lazy var contactOperations = ContactOperations(runtime: self)
    var openConversation: ((ChatConversation) -> Void)?
    func receivedContact(_ contact: ChatContact, engine: ChatEngine) {
        guard self.engine === engine else { return }
        for runtime in Self.instances.compactMap(\.value) {
            guard runtime.engine?.store.userID == engine.store.userID,
                  runtime.engine?.store.environment == engine.store.environment else { continue }
            if let index = runtime.contacts.firstIndex(where: { $0.peer.id == contact.peer.id }) {
                runtime.contacts[index] = runtime.contacts[index].merging(contact)
            } else { runtime.contacts.append(contact) }
            runtime.publish()
        }
    }
    var incomingMessages: (([ChatMessage]) -> Void)?
    private var incomingTask: Task<Void, Never>?
    private var foreground = false
    private var observers: [UUID: () -> Void] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var api: IMAPI? { session.sessionManager.map(IMAPI.init) }
    var userID: String { session.profile?.userID.uuidString.lowercased() ?? "" }
    init(session: SessionCoordinator) { self.session = session; registerInstance() }
    #if DEBUG
    /// 预览只注入确定性快照，不打开账号存储或发出网络请求。
    convenience init(previewContacts: [ChatContact]) {
        self.init(session: .configured())
        contacts = previewContacts; hasSnapshot = true
    }
    convenience init(previewConversations: [ChatConversation], pinned: Set<String>, collapsed: Bool) {
        self.init(session: .configured())
        conversations = previewConversations; hasSnapshot = true
        pinnedConversationsCollapsed = collapsed
        for conversation in previewConversations {
            var state = ConversationListState(); state.hasAppeared = true
            state.activityAt = conversation.latestMessage?.createdAt ?? 0
            listStates[conversation.id] = state
            preferences[conversation.id] = .init(isPinned: pinned.contains(conversation.id))
        }
    }
    #endif
    /// 注入已打开的账号资源，供隔离集成验证使用；不启动后台同步或创建替代密钥。
    init(session: SessionCoordinator, engine: ChatEngine, media: ChatMediaStore,
         conversations: [ChatConversation], pageLeaseRoot: URL, contacts: [ChatContact] = []) {
        self.session = session; self.engine = engine; self.media = media
        self.hasSnapshot = true
        self.contacts = contacts
        self.conversations = conversations.sorted {
                        let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
                        return left == right ? $0.id < $1.id : left > right
                    }; self.pageLeaseRoot = pageLeaseRoot
        rebuildProfileIndex()
        registerInstance()
        originalDraftStore = AccountChatDraftStore(store: engine.store, media: media)
        observeDraftSaves(engine: engine)
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
                let databaseURL = root.appendingPathComponent("main.sqlite")
                let environmentID = manager.environment.identifier
                // FTS 回填可能读取较多历史文字，不占用场景的主线程。
                let store = try await Task.detached {
                    try ChatStore(url: databaseURL, key: databaseKey, environment: environmentID, userID: user)
                }.value
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
                observeDraftSaves(engine: engine)
                self.media = media
                let transfers = ChatTransferQueue(
                    store: store, media: media, session: manager, engine: engine)
                self.transfers = transfers
                await transfers.resume()
                incomingTask = Task { [weak self, engine] in
                    let stream = await engine.incomingMessages()
                    for await messages in stream {
                        guard !Task.isCancelled, let self, self.engine === engine else { break }
                        self.incomingMessages?(messages)
                    }
                }
                await engine.setForegroundNotificationsEnabled(foreground)
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
                    self.preferences = try await store.allConversationPreferences()
                    self.conversations = conversations.sorted {
                        let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
                        return left == right ? $0.id < $1.id : left > right
                    }
                    try await self.refreshListStates()
                    if update.ownProfileVersion > (session.profile?.version ?? 0) {
                        try? await session.reloadProfile()
                        guard self.generation == generation, !Task.isCancelled else { break }
                        self.publish()
                    }
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
    private var stopping: Task<Void, Error>?
    /// 等待所有运行时释放该账号的存储访问；失败时禁止继续删除文件或密钥。
    static func stopAccount(user: UUID, environment: String) async throws {
        let targets = instances.compactMap(\.value).filter {
            $0.session.profile?.userID == user && $0.session.store.environmentID == environment
        }
        for runtime in targets { runtime.stop() }
        for runtime in targets { try await runtime.stopping?.value }
    }
    func stop() {
        guard stopping == nil else { return }
        generation = UUID()
        incomingTask?.cancel(); incomingTask = nil
        preferences = [:]
        listStates = [:]
        draftPreviews = [:]
        pinnedConversationsCollapsed = false
        listRefresh = UUID()
        let starting = task
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
        stopping = Task {
            await starting?.value
            await transfers?.stop()
            await old?.stop()
            try await media?.clearLeases()
            if let pages, FileManager.default.fileExists(atPath: pages.path) { try FileManager.default.removeItem(at: pages) }
            try await old?.store.close()
        }
    }
    func setForeground(_ enabled: Bool) {
        guard foreground != enabled else { return }
        foreground = enabled
        let engine = engine
        Task {
            await engine?.setForegroundNotificationsEnabled(enabled)
            if enabled { try? await engine?.synchronize() }
        }
    }
    func preference(_ id: String) -> ConversationLocalPreferences { preferences[id] ?? .init() }
    func setPreference(_ value: ConversationLocalPreferences, conversation: String) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        try await engine.store.setConversationPreferences(value, conversation: conversation)
        guard self.engine === engine else { throw ChatStoreError.unavailable }
        publishPreference(value, conversation: conversation, engine: engine)
    }
    func updatePreference(conversation: String, isPinned: Bool? = nil, isMuted: Bool? = nil) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        let value = try await engine.store.updateConversationPreferences(conversation: conversation, isPinned: isPinned, isMuted: isMuted)
        guard self.engine === engine else { throw ChatStoreError.unavailable }
        publishPreference(value, conversation: conversation, engine: engine)
    }
    private func publishPreference(_ value: ConversationLocalPreferences, conversation: String, engine: ChatEngine) {
        for runtime in Self.instances.compactMap(\.value) {
            guard let other = runtime.engine, other.store.userID == engine.store.userID,
                  other.store.environment == engine.store.environment else { continue }
            runtime.preferences[conversation] = value
            runtime.publish()
        }
    }
    var sortedConversations: [ChatConversation] {
        conversations.sorted {
            let left = preference($0.id).isPinned, right = preference($1.id).isPinned
            if left != right { return left }
            let a = listStates[$0.id]?.activityAt ?? $0.latestMessage?.createdAt ?? 0
            let b = listStates[$1.id]?.activityAt ?? $1.latestMessage?.createdAt ?? 0
            return a == b ? $0.id < $1.id : a > b
        }
    }
    var visibleSortedConversations: [ChatConversation] {
        sortedConversations.filter { listStates[$0.id]?.isVisible == true }
    }
    /// 读取持久列表状态并刷新同账号场景；较早的读取不能覆盖较新的请求。
    func refreshListStates() async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        let targets = Self.instances.compactMap(\.value).filter {
            $0.engine?.store.userID == engine.store.userID && $0.engine?.store.environment == engine.store.environment
        }
        let request = UUID()
        for target in targets { target.listRefresh = request }
        let snapshot = try await engine.store.conversationListSnapshot()
        guard self.engine === engine else { return }
        for target in targets where target.listRefresh == request && target.engine != nil {
            target.listStates = snapshot.states
            target.draftPreviews = snapshot.drafts
            target.pinnedConversationsCollapsed = snapshot.pinnedCollapsed
            target.publish()
        }
    }
    private func observeDraftSaves(engine: ChatEngine) {
        originalDraftStore?.didSave = { [weak self, weak engine] in
            guard let self, let engine, self.engine === engine else { return }
            try? await refreshListStates()
        }
    }
    func setPinnedConversationsCollapsed(_ collapsed: Bool) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        try await engine.store.setPinnedConversationsCollapsed(collapsed)
        guard self.engine === engine else { return }
        try await refreshListStates()
    }
    func markConversationUnread(_ conversation: String, enabled: Bool = true) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        try await engine.store.setManuallyUnread(enabled, conversation: conversation)
        guard self.engine === engine else { return }
        try await refreshListStates()
    }
    func hideConversation(_ conversation: String, deleting: Bool = false) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        try await engine.store.hideConversation(conversation, clearHistory: deleting)
        guard self.engine === engine else { return }
        try await refreshListStates()
        changed()
    }
    /// 页面实际可见后消除手动提醒；失败时保留提醒，下一次进入仍可重试。
    func enteredConversation(_ conversation: String) {
        guard let engine else { return }
        Task {
            guard self.engine === engine else { return }
            do {
                try await engine.store.setManuallyUnread(false, conversation: conversation)
                guard self.engine === engine else { return }
                try await refreshListStates()
            } catch { /* 保留持久标记，下一次进入页面时重试。 */ }
        }
    }
    func displayName(user id: String, fallback: ChatUser? = nil) -> String {
        let contact = contacts.first { $0.peer.id == id }
        var profile = profileIndex[id] ?? fallback
        if let fallback, profile == nil || fallback.version > profile!.version { profile = fallback }
        if id == userID, let own = session.profile, own.version >= (profile?.version ?? 0) { return own.nickname }
        if profile?.deleted == true { return Localization.text("account.deletedUser") }
        if let remark = contact?.remark, !remark.isEmpty { return remark }
        return profile?.nickname ?? Localization.text("chat.live.groupMember")
    }
    func memberName(_ member: ChatMember) -> String { displayName(user: member.id, fallback: member.profile) }
    func title(_ conversation: ChatConversation) -> String {
        let conversation = conversations.first { $0.id == conversation.id } ?? conversation
        if conversation.kind == "group" { return conversation.title }
        guard let peer = conversation.members.first(where: { $0.id != userID }) else { return Localization.text("chat.live.privateChat") }
        return memberName(peer)
    }
    func canSend(_ conversation: ChatConversation) -> Bool {
        let conversation = conversations.first { $0.id == conversation.id } ?? conversation
        return !conversation.closed
            && conversation.members.contains { $0.id == userID && $0.active }
            && (conversation.kind == "group"
                || contacts.contains {
                    $0.canSend
                        && $0.peer.id == conversation.members.first(where: { $0.id != userID })?.id
                })
    }
    func refresh() { Task { try? await engine?.synchronize() } }
    /// 等待共享同步结束，供刷新控件结束动画；存储不可用时不创建替代数据库。
    func refreshAndWait() async { try? await engine?.synchronize() }
    func changed() {
        guard let engine else { return }
        Task {
            guard self.engine === engine else { return }
            try? await refreshListStates()
            guard self.engine === engine else { return }
            let engines = Self.instances.compactMap(\.value).compactMap(\.engine).filter {
                $0.store.userID == engine.store.userID && $0.store.environment == engine.store.environment
            }
            for engine in engines { await engine.changed() }
        }
    }
    deinit { task?.cancel(); incomingTask?.cancel() }
}
