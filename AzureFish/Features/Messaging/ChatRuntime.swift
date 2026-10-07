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
    private var accountStorage: AccountBusinessStorage?
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
    private(set) var hasContactSnapshot = false
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
    private static var contactChecks: [String: (id: UUID, engine: ChatEngine, task: Task<ChatContact, Error>)] = [:]
    /// 同账号、同联系人只进行一次并发校验；写入完成后发布版本合并后的资料。
    @discardableResult
    func refreshContact(peer: String) async throws -> ChatContact {
        guard let engine, let api else { throw ChatStoreError.unavailable }
        let scope = engine.store.environment + ":" + engine.store.userID.uuidString + ":" + peer
        let request: Task<ChatContact, Error>
        if let pending = Self.contactChecks[scope] { request = pending.task }
        else {
            let id = UUID()
            request = Task { [self] in
                defer { if Self.contactChecks[scope]?.id == id { Self.contactChecks[scope] = nil } }
                let value = try await api.contact(peer: peer)
                try Task.checkCancellation()
                guard self.engine === engine else { throw CancellationError() }
                try await engine.store.save(value)
                try Task.checkCancellation()
                guard self.engine === engine else { throw CancellationError() }
                receivedContact(value, engine: engine)
                return contacts.first { $0.peer.id == peer } ?? value
            }
            Self.contactChecks[scope] = (id, engine, request)
        }
        let result = try await request.value
        try Task.checkCancellation()
        guard self.engine === engine else { throw CancellationError() }
        return contacts.first { $0.peer.id == peer }.map { $0.merging(result) } ?? result
    }
    /// 先发布本地通讯录；其他列表恢复与网络任务不会阻塞这次发布。
    func restoreDirectory(engine: ChatEngine) async throws {
        let snapshot = try await engine.store.contactDirectorySnapshot()
        try Task.checkCancellation()
        guard self.engine === engine else { throw CancellationError() }
        let previous = Dictionary(uniqueKeysWithValues: contacts.map { ($0.peer.id, $0) })
        var restored = Dictionary(uniqueKeysWithValues: snapshot.contacts.map { ($0.peer.id, $0) })
        for (id, old) in previous { restored[id] = restored[id].map { old.merging($0) } ?? old }
        contacts = restored.values.sorted { $0.peer.id < $1.peer.id }
        hasContactSnapshot = snapshot.hasSnapshot
        publish()
    }
    var incomingMessages: (([ChatMessage]) -> Void)?
    private var incomingTask: Task<Void, Never>?
    private var foreground = false
    private var observers: [UUID: (ChatEngineUpdate?) -> Void] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var api: IMAPI? { session.readOnly ? nil : session.sessionManager.map(IMAPI.init) }
    var userID: String { session.profile?.userID.uuidString.lowercased() ?? "" }
    init(session: SessionCoordinator) { self.session = session; registerInstance() }
    #if DEBUG
    /// 预览只注入确定性快照，不打开账号存储或发出网络请求。
    convenience init(previewContacts: [ChatContact]) {
        self.init(session: .configured())
        contacts = previewContacts; hasContactSnapshot = true; hasSnapshot = true
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
         conversations: [ChatConversation], pageLeaseRoot: URL, contacts: [ChatContact] = [], transfers: ChatTransferQueue? = nil) {
        self.session = session; self.engine = engine; self.media = media
        self.hasSnapshot = true
        self.hasContactSnapshot = true
        self.contacts = contacts
        self.conversations = conversations.sorted {
            let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
            return left == right ? $0.id < $1.id : left > right
        }
        self.pageLeaseRoot = pageLeaseRoot
        rebuildProfileIndex()
        registerInstance()
        originalDraftStore = AccountChatDraftStore(store: engine.store, media: media)
        observeDraftSaves(engine: engine)
        if let transfers { self.transfers = transfers }
        else if let manager = session.sessionManager {
            self.transfers = ChatTransferQueue(store: engine.store, media: media, session: manager, engine: engine)
        }
    }
    func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = { _ in block() }
        return id
    }
    func remove(_ id: UUID) { observers[id] = nil }
    func publish(_ update: ChatEngineUpdate? = nil) { observers.values.forEach { $0(update) } }
    /// 页面订阅随当前会话身份解析范围；状态通知不重新读取时间线。
    func observeConversation(_ conversation: @escaping () -> String?, status: @escaping () -> Void,
                             changed: @escaping (ChatChangeScope) -> Void) -> UUID {
        let id = UUID()
        observers[id] = { update in
            guard let update else { changed(.all); return }
            status()
            if update.scope.isEmpty { return }
            if update.scope.contains(.directory) || update.conversations == nil || update.conversations?.contains(conversation() ?? "") == true {
                changed(update.scope)
            }
        }
        return id
    }
    private var networkTransition: Task<Void, Never>?
    /// 保留已打开的本地存储与页面，仅暂停或恢复联网任务。
    func authenticationDidChange() {
        let previous = networkTransition
        networkTransition = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, let engine else { return }
            if session.readOnly {
                await engine.stop()
                await transfers?.pause()
                online = false
            } else {
                await engine.start()
                await engine.setForegroundNotificationsEnabled(foreground)
                await transfers?.resume()
            }
            publish()
        }
    }
    static func stopInvalidSession(user: UUID, environment: String) {
        for runtime in instances.compactMap(\.value)
            where runtime.session.profile?.userID == user && runtime.session.store.environmentID == environment {
            runtime.stop()
        }
    }
    func start() {
        guard task == nil, stopping == nil, let manager = session.sessionManager, let user = session.profile?.userID
        else { return }
        let generation = generation
        task = Task { [weak self] in
            do {
                guard let context = try await self?.openRuntime(manager: manager, user: user, generation: generation) else { return }
                let (engine, store, media, transfers) = context
                let changes = await engine.updates()
                for await update in changes {
                    guard let self, self.generation == generation, !Task.isCancelled else { break }
                    self.online = update.online && !session.readOnly
                    self.synchronization = update.synchronization
                    if update.scope.contains(.directory) { try await restoreDirectory(engine: engine) }
                    guard self.generation == generation, !Task.isCancelled else { break }
                    self.hasSnapshot = self.hasContactSnapshot
                    if update.scope.contains(.conversations) {
                        let conversations = try await store.conversations(identifiers: update.conversations)
                        guard self.generation == generation, !Task.isCancelled else { break }
                        let values = update.conversations.map { ids in
                            self.conversations.filter { !ids.contains($0.id) } + conversations
                        } ?? conversations
                        self.conversations = values.sorted {
                            let left = $0.latestMessage?.createdAt ?? 0, right = $1.latestMessage?.createdAt ?? 0
                            return left == right ? $0.id < $1.id : left > right
                        }
                        try await self.refreshListStates(publishing: false, identifiers: update.conversations)
                    }
                    self.publish(update)
                    if !session.readOnly && update.ownProfileVersion > (session.profile?.version ?? 0) {
                        try? await session.reloadProfile()
                        guard self.generation == generation, !Task.isCancelled else { break }
                        self.publish()
                    }
                    if !update.scope.isEmpty { try? await store.cleanupMedia(using: media) }
                    if update.online && !session.readOnly { await transfers.resume() }
                }
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.failure = (error as? ChatStoreError) == .incompatibleSchema ? "chat.live.incompatibleStorage" : "chat.live.storageFailure"
                self.publish()
                session.storageUnavailable(notice: self.failure)
            }
        }
    }
    private func openRuntime(manager: APISessionManager, user: UUID, generation: UUID) async throws
        -> (ChatEngine, ChatStore, ChatMediaStore, ChatTransferQueue) {
        let scope = manager.environment.identifier + ":" + user.uuidString.lowercased()
        let directoryName = SHA256.hash(data: Data(scope.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        var root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatAccounts/" + directoryName, isDirectory: true)
        guard self.generation == generation else { throw CancellationError() }
        try await AccountBusinessStorage.waitForOpening(environment: manager.environment.identifier, userID: user)
        let exists = FileManager.default.fileExists(atPath: root.path)
        let databaseURL = root.appendingPathComponent("main.sqlite")
        // 恢复只打开既有库；残留目录缺少数据库同样需要明确恢复。
        guard exists ? FileManager.default.fileExists(atPath: databaseURL.path) : session.canCreateBusinessCache
        else { throw AccountFailure.damagedCache }
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
        let account = try await AccountBusinessStorage.acquire(root: root, databaseKey: databaseKey,
            mediaKey: mediaKey, environment: manager.environment.identifier, userID: user)
        guard self.generation == generation else { try await account.release(); throw CancellationError() }
        self.accountStorage = account
        let store = try ChatStore(database: account.resources.database)
        let media = ChatMediaStore(storage: account.resources.media)
        let engine = ChatEngine(store: store, session: manager)
        let pages = root.appendingPathComponent("page-leases/" + UUID().uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: pages.path) { try FileManager.default.removeItem(at: pages) }
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        self.pageLeaseRoot = pages
        self.originalDraftStore = AccountChatDraftStore(store: store, media: media)
        self.engine = engine
        session.didOpenBusinessCache()
        observeDraftSaves(engine: engine)
        self.media = media
        let transfers = ChatTransferQueue(
            store: store, media: media, session: manager, engine: engine)
        self.transfers = transfers
        try await restoreDirectory(engine: engine)
        self.conversations = try await store.conversations()
        self.preferences = try await store.allConversationPreferences()
        self.hasSnapshot = self.hasContactSnapshot
        try await refreshListStates()
        publish()
        incomingTask = Task { [weak self, engine] in
            let stream = await engine.incomingMessages()
            for await messages in stream {
                guard !Task.isCancelled, let self, self.engine === engine else { break }
                self.incomingMessages?(messages)
            }
        }
        await engine.setForegroundNotificationsEnabled(foreground)
        authenticationDidChange()
        return (engine, store, media, transfers)
    }
    isolated deinit { stop() }

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
        networkTransition?.cancel()
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
        let checks = Self.contactChecks.values.filter { $0.engine === old }.map(\.task)
        checks.forEach { $0.cancel() }
        let media = media
        let accountStorage = accountStorage
        self.accountStorage = nil
        let transfers = transfers
        let pages = pageLeaseRoot
        pageLeaseRoot = nil
        let drafts = originalDraftStore
        originalDraftStore = nil
        engine = nil
        self.media = nil
        self.transfers = nil
        contacts = []
        conversations = []
        online = false
        hasSnapshot = false
        hasContactSnapshot = false
        synchronization = .idle
        failure = nil
        publish()
        stopping = Task {
            await starting?.value
            for check in checks { _ = try? await check.value }
            await drafts?.stopAndWait()
            await transfers?.stop()
            await old?.stop()
            if accountStorage == nil { try await media?.clearLeases() }
            if let pages, FileManager.default.fileExists(atPath: pages.path) { try FileManager.default.removeItem(at: pages) }
            try await old?.store.close()
            try await accountStorage?.release()
        }
    }
    func setForeground(_ enabled: Bool) {
        guard foreground != enabled else { return }
        foreground = enabled
        let engine = engine
        Task {
            await engine?.setForegroundNotificationsEnabled(enabled)
            if enabled && !session.readOnly { try? await engine?.synchronize() }
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
    func refreshListStates(publishing: Bool = true, identifiers: Set<String>? = nil) async throws {
        guard let engine else { throw ChatStoreError.unavailable }
        let targets = Self.instances.compactMap(\.value).filter {
            $0.engine?.store.userID == engine.store.userID && $0.engine?.store.environment == engine.store.environment
        }
        let request = UUID()
        for target in targets { target.listRefresh = request }
        let snapshot = try await engine.store.conversationListSnapshot(identifiers: identifiers)
        guard self.engine === engine else { return }
        for target in targets where target.listRefresh == request && target.engine != nil {
            if let identifiers {
                for id in identifiers { target.listStates[id] = snapshot.states[id]; target.draftPreviews[id] = snapshot.drafts[id] }
            } else {
                target.listStates = snapshot.states
                target.draftPreviews = snapshot.drafts
            }
            target.pinnedConversationsCollapsed = snapshot.pinnedCollapsed
            if publishing { target.publish() }
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
    /// 返回跨通讯录和会话合并的最新头像身份；删除标记优先于旧资源。
    func avatarAsset(user: String, fallback: ChatUser? = nil) -> String? {
        var profile = profileIndex[user] ?? fallback
        if let fallback, fallback.version > (profile?.version ?? -1) { profile = fallback }
        if user == userID, let own = session.profile, own.version >= (profile?.version ?? -1) { return own.avatarID }
        return profile?.deleted == true ? nil : profile?.avatarID
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
        !session.readOnly && canCompose(conversation)
    }
    /// 本地草稿编辑不要求联网确认，但仍遵守会话成员与关闭状态。
    func canCompose(_ conversation: ChatConversation) -> Bool {
        let conversation = conversations.first { $0.id == conversation.id } ?? conversation
        return !conversation.closed
            && conversation.members.contains { $0.id == userID && $0.active }
            && (conversation.kind == "group"
                || contacts.contains {
                    $0.canSend
                        && $0.peer.id == conversation.members.first(where: { $0.id != userID })?.id
                })
    }
    func refresh() { Task { await refreshAndWait() } }
    /// 等待共享同步结束，供刷新控件结束动画；存储不可用时不创建替代数据库。
    func refreshAndWait() async {
        if session.readOnly { await session.restore() }
        if !session.readOnly { try? await engine?.synchronize() }
    }
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
}
