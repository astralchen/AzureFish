import Foundation
import CryptoKit
import AzureFishAPI
import UIKit
import Network

/// 协调单个应用会话的恢复、刷新、资料和退出，拒绝已退出代次的迟到响应。
@MainActor
final class SessionCoordinator {
    private final class WeakSession {
        weak var value: SessionCoordinator?
        init(_ value: SessionCoordinator) { self.value = value }
    }
    private static var instances: [WeakSession] = []
    // 同一环境的所有场景共用协调器、认证存储和刷新任务。
    private static var configuredSessions: [String: SessionCoordinator] = [:]
    enum Connectivity: Equatable { case checking, online, offline }
    private(set) var connectivity: Connectivity = .checking
    var readOnly: Bool { connectivity != .online }
    var rememberedAccount: RememberedLoginAccount? { try? store.rememberedAccount() }
    private var observers: [UUID: () -> Void] = [:]
    private var activeScenes: Set<UUID> = []
    private var renewalTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var localRestored = false
    /// 仅刚完成密码认证的账号可初始化业务库；冷启动不得补建缺失缓存。
    private(set) var canCreateBusinessCache = false
    func didOpenBusinessCache() { canCreateBusinessCache = false }
    private var managerObservation: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    func observe(_ body: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = body; return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func setActive(_ active: Bool, scene: UUID) {
        let wasActive = !activeScenes.isEmpty
        if active { activeScenes.insert(scene) } else { activeScenes.remove(scene) }
        if activeScenes.isEmpty { renewalTask?.cancel(); renewalTask = nil }
        else if !wasActive { retryConnection() }
    }
    func retryConnection() {
        guard phase == .signedIn || phase == .recovery, !busy, validationTask == nil else { return }
        validationTask = Task { [weak self] in
            guard let self else { return }
            await restore()
            validationTask = nil
        }
    }
    private func startConnectivityMonitoring() {
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, !activeScenes.isEmpty else { return }
                if available {
                    if connectivity != .online { retryConnection() }
                } else if phase == .signedIn, !busy {
                    connectivity = .offline
                    renewalTask?.cancel()
                    await sessionManager?.setNetworkAccessAllowed(false)
                    publish()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "azurefish.session.connectivity"))
    }
    private func scheduleRenewal() {
        renewalTask?.cancel(); renewalTask = nil
        guard phase == .signedIn, connectivity == .online, !activeScenes.isEmpty,
              let credentials = try? stored?.credentials() else { return }
        let delay = max(1, credentials.accessExpiresAt.timeIntervalSinceNow)
        renewalTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400) * 1_000_000_000)) }
            catch { return }
            self?.retryConnection()
        }
    }
    enum Phase: Equatable { case restoring, welcome, signedIn, recovery }
    private(set) var phase: Phase = .restoring
    private(set) var profile: AccountProfile?
    private(set) var noticeKey: String?
    private(set) var busy = false
    var didChange: (() -> Void)?
    let service: (any AccountServicing)?
    let store: CredentialStore
    let sessionManager: APISessionManager?
    private let repository: UserRepository
    var sessionIdentity: String? { stored.map { $0.userID.uuidString + ":" + $0.sessionID.uuidString } }
    private var stored: StoredSession?
    private var epoch = UUID()
    private var refreshTask: Task<SessionCredentials, Error>?
    private var authentication: (AuthenticationInput, AccountOperation<AuthenticatedSession>)?
    private var profileOperation: (AccountProfile, String, String, AccountOperation<UserProfile>)?
    private var securityOperation: (AccountSecurityAction, String, AccountOperation<Bool>, SessionCredentials)?
    private var avatarOperation: (Data, AccountOperation<UserProfile>)?
    private var avatarsSuspended = false
    private var exitPending = false
    private var invalidationTask: Task<Void, Never>?
    private var pendingLogout: LogoutRevocation?
    private var requests: [UUID: () -> Void] = [:]

    init(service: (any AccountServicing)?, store: CredentialStore, repository: UserRepository) {
        self.service = service; self.store = store; self.repository = repository
        sessionManager = service.map { APISessionManager(api: $0.api, store: KeychainAPISessionStore(store: store)) }
        Self.instances.removeAll { $0.value == nil }; Self.instances.append(WeakSession(self))
        if let sessionManager {
            managerObservation = Task { [weak self] in
                for await state in await sessionManager.changes() {
                    guard !Task.isCancelled else { break }
                    guard state.requiresReauthentication, let self, !busy, phase == .signedIn else { continue }
                    await endInvalidSession()
                    publish()
                }
            }
        }
    }
    static func configured() -> SessionCoordinator {
        let service = LiveAccountService.configured()
        let keys = KeychainValueStore()
        let environment = service?.api.environment.identifier ?? "unconfigured"
        if let existing = configuredSessions[environment] { return existing }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountProfiles", isDirectory: true)
        let session = SessionCoordinator(service: service, store: CredentialStore(values: keys, environmentID: environment),
            repository: UserRepository(root: root, keys: keys, environment: environment))
        configuredSessions[environment] = session
        session.startConnectivityMonitoring()
        return session
    }
    private func publish() {
        didChange?(); Array(observers.values).forEach { $0() }
        if !busy { scheduleRenewal() }
    }
    /// 本账号存储无法安全打开时退出内容界面，保留原文件及凭据供明确恢复。
    func storageUnavailable(notice: String? = nil) {
        epoch = UUID(); renewalTask?.cancel()
        profile = nil; connectivity = .offline; phase = .recovery; noticeKey = notice ?? AccountFailure.storage.key
        Task { await sessionManager?.setNetworkAccessAllowed(false) }
        publish()
    }
    private func check(_ generation: UUID) throws {
        guard epoch == generation, !exitPending else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func restore() async {
        guard !busy else { return }
        busy = true; noticeKey = nil
        let generation = epoch
        connectivity = .checking; publish()
        defer { busy = false; publish() }
        guard let sessionManager else { phase = .welcome; noticeKey = AccountFailure.unavailable.key; return }
        await sessionManager.setNetworkAccessAllowed(false)
        do {
            try await recoverDeletionRequest()
            try await recoverLocalDeletion()
            try check(generation)
            stored = try store.load()
            guard let stored else { profile = nil; phase = .welcome; await drainRevocations(); return }
            if !localRestored {
                try await sessionManager.restoreLocal()
                localRestored = true
            }
            try check(generation)
            guard let cached = try repository.load(user: stored.userID) else { throw AccountFailure.damagedCache }
            profile = cached; avatarsSuspended = false; phase = .signedIn; publish()
            let value = try await sessionManager.validateSession()
            try check(generation)
            self.stored = try store.load()
            acceptProfile(AccountProfile(value))
            await sessionManager.setNetworkAccessAllowed(true)
            try check(generation)
            connectivity = .online; avatarsSuspended = false; phase = .signedIn
            publish()
            await drainRevocations()
        } catch {
            guard epoch == generation else { return }
            noticeKey = AccountFailure.key(for: error)
            if isTerminal(error) { await endInvalidSession() }
            else if let failure = error as? AccountFailure,
                    [.storage, .missingKey, .damagedCache].contains(failure) {
                if let user = stored?.userID { ChatRuntime.stopInvalidSession(user: user, environment: store.environmentID) }
                profile = nil; connectivity = .offline; phase = .recovery
            } else {
                connectivity = .offline
                if profile?.userID == stored?.userID, profile != nil { phase = .signedIn }
                else { phase = .recovery }
            }
        }
    }
    private func endInvalidSession() async {
        if let invalidationTask { await invalidationTask.value; return }
        let task = Task { await performInvalidSessionEnd() }
        invalidationTask = task
        await task.value
        invalidationTask = nil
    }
    private func performInvalidSessionEnd() async {
        let wasBusy = busy; busy = true
        defer { busy = wasBusy }
        renewalTask?.cancel()
        invalidateAvatars()
        if let user = stored?.userID { ChatRuntime.stopInvalidSession(user: user, environment: store.environmentID) }
        epoch = UUID(); requests.values.forEach { $0() }; requests.removeAll()
        authentication = nil; profileOperation = nil; securityOperation = nil; avatarOperation = nil; pendingLogout = nil
        profile = nil; connectivity = .checking
        do {
            let cleanup = Task { try await sessionManager?.clearLocalSession() }
            try await cleanup.value
            stored = nil; profile = nil; localRestored = false; connectivity = .checking
            phase = .welcome; noticeKey = AccountFailure.expired.key
        } catch { phase = .recovery; noticeKey = AccountFailure.storage.key }
    }
    func authenticate(_ input: AuthenticationInput) async throws {
        guard !busy else { throw AccountFailure.busy }
        guard let api = service?.api else { throw AccountFailure.unavailable }
        guard AccountValidation.account(input.account), AccountValidation.password(input.password),
              !input.register || AccountValidation.nickname(input.nickname) else { throw AccountFailure.invalidInput }
        busy = true; publish()
        let generation = epoch
        defer { busy = false; publish() }
        // 未决删除先恢复，避免换号后用新会话覆盖旧账号的清理状态。
        try await recoverDeletionRequest()
        try await recoverLocalDeletion()
        if authentication?.0 != input {
            let device = try store.installationID()
            let operation = try input.register
                ? api.prepareRegistration(operationID: UUID(), deviceID: device, accountName: input.account, password: input.password, nickname: input.nickname)
                : api.prepareLogin(operationID: UUID(), deviceID: device, accountName: input.account, password: input.password)
            authentication = (input, operation)
        }
        let result: AuthenticatedSession
        do { result = try await api.execute(authentication!.1) }
        catch APIClientError.service(let failure) where failure.code == .authAttemptExpired {
            authentication = nil
            throw APIClientError.service(failure)
        }
        try check(generation)
        try await install(result, generation: generation)
        authentication = nil; avatarsSuspended = false; phase = .signedIn
        scheduleRenewal()
    }
    /// 放弃表单时废弃当前代次；已发出请求可能在服务端完成，但不会安装迟到会话。
    func cancelAuthentication() {
        epoch = UUID(); authentication = nil
    }
    private func install(_ result: AuthenticatedSession, generation: UUID) async throws {
        let value = StoredSession(result.credentials)
        if stored?.userID != value.userID { await invalidateAvatars()?.value }
        try check(generation)
        do {
            try await sessionManager?.install(result.credentials)
            try check(generation)
        } catch {
            guard epoch != generation || Task.isCancelled else { throw error }
            // 放弃可能发生在 Keychain 写入等待期间；清理不继承已取消表单的取消状态。
            let cleanup = Task { try await sessionManager?.clearLocalSession() }
            do { try await cleanup.value }
            catch { phase = .recovery; noticeKey = AccountFailure.storage.key }
            throw CancellationError()
        }
        stored = value
        canCreateBusinessCache = true
        avatarsSuspended = false
        acceptProfile(AccountProfile(result.profile))
        connectivity = .online; localRestored = true
        await sessionManager?.setNetworkAccessAllowed(true)
    }
    private func acceptProfile(_ value: AccountProfile) {
        guard stored?.userID == value.userID else { return }
        if let profile, profile.userID == value.userID, profile.version > value.version { return }
        profile = value
        try? store.remember(value)
        do { try repository.save(value); noticeKey = nil }
        catch { noticeKey = "account.saved.storage" }
    }
    private func refresh() async throws -> SessionCredentials {
        guard let sessionManager else { throw AccountFailure.expired }
        let generation = epoch
        let credentials = try await sessionManager.refresh()
        try check(generation); stored = try store.load()
        return credentials
    }
    private func authorized<T: Sendable>(_ work: @escaping @MainActor @Sendable (AccountAPI, SessionCredentials) async throws -> T) async throws -> T {
        let id = UUID()
        let task = Task { @MainActor in try await self.performAuthorized(work) }
        requests[id] = { task.cancel() }
        defer { requests[id] = nil }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if (isTerminal(error) || invalidationTask != nil), !exitPending {
                await endInvalidSession()
                publish()
            }
            throw error
        }
    }
    private func performAuthorized<T: Sendable>(_ work: @escaping @MainActor @Sendable (AccountAPI, SessionCredentials) async throws -> T) async throws -> T {
        guard let api = service?.api, let sessionManager else { throw AccountFailure.expired }
        let generation = epoch
        let result = try await sessionManager.authorized { credentials in try await work(api, credentials) }
        try check(generation); stored = try store.load()
        return result
    }
    func reloadProfile() async throws {
        let value = try await authorized { api, credentials in try await api.profile(using: credentials) }
        acceptProfile(AccountProfile(value)); publish()
    }
    /// 保存只包含改动字段；同一草稿网络重试使用相同操作和正文字节。
    func saveProfile(base: AccountProfile, nickname: String, bio: String) async throws {
        guard !busy else { throw AccountFailure.busy }
        guard !readOnly else { throw AccountFailure.offline }
        guard AccountValidation.nickname(nickname), AccountValidation.bio(bio) else { throw AccountFailure.invalidInput }
        guard nickname != base.nickname || bio != base.bio else { return }
        guard let api = service?.api, let credentials = try stored?.credentials(), base.userID == credentials.userID else { throw AccountFailure.expired }
        busy = true; publish()
        defer { busy = false; publish() }
        if profileOperation?.0 != base || profileOperation?.1 != nickname || profileOperation?.2 != bio {
            let changes = ProfileChanges(expectedVersion: base.version, nickname: nickname == base.nickname ? nil : nickname,
                bio: bio == base.bio ? nil : bio)
            profileOperation = (base, nickname, bio, try api.prepareProfileUpdate(operationID: UUID(), changes: changes, using: credentials))
        }
        let operation = profileOperation!.3
        do {
            let result = try await authorized { api, credentials in try await api.execute(operation, using: credentials) }
            acceptProfile(AccountProfile(result)); profileOperation = nil
        } catch APIClientError.service(let error) where error.code == .operationResultExpired {
            profileOperation = nil
            try await reloadProfile()
            if profile?.nickname != nickname || profile?.bio != bio { throw AccountFailure.conflict }
        } catch APIClientError.service(let error) where error.code == .profileVersionConflict {
            profileOperation = nil
            try await reloadProfile()
            throw AccountFailure.conflict
        }
    }
    /// 先尝试撤销服务端会话。失败时允许用户明确选择本机退出，补偿只持有旧访问凭据。
    ///
    /// 结果不确定时保留当前页面并转为只读；恢复须重新加载本地记录并通过服务端校验。
    func logout(localOnly: Bool = false) async throws {
        guard !busy else { throw AccountFailure.busy }
        stored = try store.load()
        guard let api = service?.api, var credentials = try stored?.credentials() else {
            await invalidateAvatars()?.value
            try store.clear(); phase = .welcome; profile = nil; stored = nil; localRestored = false; renewalTask?.cancel(); publish(); return
        }
        busy = true
        defer {
            if phase == .signedIn {
                for session in Self.instances.compactMap(\.value)
                    where session.store.environmentID == store.environmentID && session.stored?.userID == stored?.userID {
                    session.avatarsSuspended = false
                }
            }
            busy = false; exitPending = false; publish()
        }
        var generation = epoch
        do {
            // 失败退出后的管理器仍处于 endingSession；再次退出的刷新由 logout 自行协调。
            if !localOnly, pendingLogout == nil,
               stored?.pendingRefreshID != nil || credentials.accessExpiresAt <= Date() {
                credentials = try await refresh()
            }
            exitPending = true; epoch = UUID(); generation = epoch; refreshTask?.cancel()
            await invalidateAvatars()?.value
            requests.values.forEach { $0() }; requests.removeAll()
            // 保留业务身份，但每次使用当前存储的 Bearer 和截止时间构造补偿材料。
            let ticket = try api.prepareLogoutRevocation(operationID: pendingLogout?.operationID ?? UUID(), using: credentials)
            pendingLogout = ticket
            if localOnly {
                var queue = try store.revocations().filter { $0.expiresAt > Date() }
                if ticket.expiresAt > Date() { queue.append(ticket) }
                try store.saveRevocations(queue)
            } else {
                try await sessionManager?.logout(operationID: ticket.operationID)
            }
            try await ChatRuntime.stopAccount(user: credentials.userID, environment: store.environmentID)
            try await sessionManager?.clearLocalSession()
            try await endOtherWindows(user: credentials.userID)
            avatarOperation = nil; securityOperation = nil
            stored = nil; profile = nil; authentication = nil; profileOperation = nil; pendingLogout = nil
            connectivity = .checking; localRestored = false; noticeKey = nil; phase = .welcome
            renewalTask?.cancel()
        } catch {
            if epoch == generation {
                await sessionManager?.setNetworkAccessAllowed(false)
                if epoch == generation {
                    localRestored = false
                    connectivity = .offline
                    noticeKey = AccountFailure.key(for: error)
                    renewalTask?.cancel(); renewalTask = nil
                }
            }
            throw error
        }
    }
    func securityInfo() async throws -> AccountSecurityInfo {
        try await authorized { api, credentials in try await api.security(using: credentials) }
    }
    /// 网络重试复用原敏感操作；服务端撤销当前会话后不自动刷新凭据。
    func performSecurity(_ action: AccountSecurityAction, password: String, newPassword: String = "") async throws {
        guard !readOnly else { throw AccountFailure.offline }
        guard !busy, let api = service?.api, let manager = sessionManager else { throw AccountFailure.busy }
        busy = true; publish()
        defer { busy = false; publish() }
        let generation = epoch
        if securityOperation?.0 != action || securityOperation?.1 != newPassword {
            let credentials = try await manager.credentials()
            let proof = try await api.execute(api.prepareReauthentication(operationID: UUID(), password: password, action: action, using: credentials), using: credentials)
            try check(generation)
            let op = try api.prepareSecurityAction(operationID: UUID(), action: action, proof: proof, newPassword: newPassword, using: credentials)
            securityOperation = (action, newPassword, op, credentials)
        }
        guard let pending = securityOperation else { throw AccountFailure.invalidInput }
        if action == .deleteAccount {
            let recovery = try api.deletionRecovery(for: pending.2, using: pending.3)
            if try store.values.read(deletionRequestKey) == nil {
                try store.values.write(JSONEncoder().encode(recovery), key: deletionRequestKey)
            }
        }
        do { _ = try await api.execute(pending.2, using: pending.3) }
        catch APIClientError.service(let failure) where failure.code == .reauthRequired || failure.code == .ownerTransferRequired {
            if action == .deleteAccount { try store.values.remove(deletionRequestKey) }
            securityOperation = nil; throw APIClientError.service(failure)
        }
        try check(generation)
        if action == .deleteAccount {
            // 标记先于文件清理；失败或进程退出后，启动先完成清理再恢复会话。
            try store.values.write(Data(pending.3.userID.uuidString.utf8), key: deletionKey)
        }
        try await ChatRuntime.stopAccount(user: pending.3.userID, environment: store.environmentID)
        invalidateAvatars()
        epoch = UUID(); requests.values.forEach { $0() }; requests.removeAll()
        try await manager.clearLocalSession()
        try await endOtherWindows(user: pending.3.userID)
        if action == .deleteAccount { try await recoverLocalDeletion() }
        securityOperation = nil; avatarOperation = nil
        authentication = nil; profileOperation = nil; pendingLogout = nil
        stored = nil; profile = nil; connectivity = .checking; localRestored = false; phase = .welcome
        renewalTask?.cancel()
        noticeKey = action == .deleteAccount ? "account.deletion.accepted" : "account.security.completed"
    }
    private func endOtherWindows(user: UUID) async throws {
        for other in Self.instances.compactMap(\.value) where other !== self && other.store.environmentID == store.environmentID && other.profile?.userID == user {
            other.invalidateAvatars()
            other.epoch = UUID(); other.requests.values.forEach { $0() }; other.requests.removeAll()
            other.refreshTask?.cancel(); other.profile = nil; other.stored = nil
            other.avatarOperation = nil; other.securityOperation = nil
            other.authentication = nil; other.profileOperation = nil; other.connectivity = .checking; other.localRestored = false
            do { try await other.sessionManager?.clearLocalSession(); other.phase = .welcome }
            catch { other.phase = .recovery; other.noticeKey = AccountFailure.storage.key; other.publish(); throw error }
            other.publish()
        }
    }
    private var deletionKey: String { "pending-account-deletion." + store.environmentID }
    private var deletionRequestKey: String { "pending-account-deletion-request." + store.environmentID }
    private func recoverDeletionRequest() async throws {
        // 已确认的清理任务不再依赖网络或结果恢复窗口。
        if try store.values.read(deletionKey) != nil { return }
        guard let bytes = try store.values.read(deletionRequestKey), let api = service?.api else { return }
        let recovery = try JSONDecoder().decode(AccountDeletionRecovery.self, from: bytes)
        guard recovery.expiresAt > Date() else {
            try store.values.remove(deletionRequestKey)
            noticeKey = "account.security.resultUnknown"
            return
        }
        do { try await api.recoverDeletion(recovery) }
        catch APIClientError.service(let failure) where failure.code == .reauthRequired || failure.code == .ownerTransferRequired {
            try store.values.remove(deletionRequestKey)
            return
        }
        try store.values.write(Data(recovery.userID.uuidString.utf8), key: deletionKey)
        noticeKey = "account.deletion.accepted"
    }
    private func recoverLocalDeletion() async throws {
        guard let bytes = try store.values.read(deletionKey) else { return }
        guard let user = UUID(uuidString: String(decoding: bytes, as: UTF8.self)) else { throw AccountFailure.storage }
        try await ChatRuntime.stopAccount(user: user, environment: store.environmentID)
        try await endOtherWindows(user: user)
        await AccountAvatarLoader.invalidate(scope: .init(environment: store.environmentID, user: user))?.value
        let scope = store.environmentID + ":" + user.uuidString.lowercased()
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChatAccounts/" + hash)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        let avatars = AccountAvatarCache(keys: store.values, environment: store.environmentID, user: user)
        try repository.deleteFiles(user: user)
        try avatars.deleteFiles()
        try repository.deleteKey(user: user)
        try avatars.deleteKey()
        try store.values.remove("chat.database." + scope)
        try store.values.remove("chat.media." + scope)
        try await sessionManager?.clearLocalSession()
        try store.forgetAccount(user: user)
        try store.values.remove(deletionRequestKey)
        try store.values.remove(deletionKey)
    }
    func updateAvatar(_ jpeg: Data) async throws {
        guard !readOnly else { throw AccountFailure.offline }
        guard !busy, let api = service?.api, let profile, let manager = sessionManager else { throw AccountFailure.busy }
        busy = true; publish(); defer { busy = false; publish() }
        if avatarOperation?.0 != jpeg {
            let credentials = try await manager.credentials()
            avatarOperation = (jpeg, try api.prepareAvatar(operationID: UUID(), expectedVersion: profile.version, jpeg: jpeg, using: credentials))
        }
        let operation = avatarOperation!.1
        do {
            let value = try await authorized { api, credentials in try await api.execute(operation, using: credentials) }
            acceptProfile(AccountProfile(value)); avatarOperation = nil
        } catch APIClientError.service(let failure) where failure.code == .profileVersionConflict || failure.code == .operationResultExpired {
            avatarOperation = nil; try await reloadProfile(); throw AccountFailure.conflict
        }
    }
    var avatarScope: AccountAvatarLoader.Scope? {
        guard !exitPending, !avatarsSuspended, phase == .signedIn, let owner = stored?.userID else { return nil }
        return .init(environment: store.environmentID, user: owner)
    }
    /// 同步读取已解码图片，不进行磁盘或网络访问。
    func cachedAvatar(user: UUID, asset: String) -> UIImage? {
        guard let scope = avatarScope else { return nil }
        return try? AccountAvatarLoader.shared(scope: scope, keys: store.values).cached(.init(user: user, asset: asset))
    }
    func avatar(user: UUID, asset: String) async throws -> UIImage? {
        guard let scope = avatarScope else { throw CancellationError() }
        let loader = try AccountAvatarLoader.shared(scope: scope, keys: store.values)
        let generation = epoch
        let image = try await loader.image(.init(user: user, asset: asset)) { [self] in
            let result = try await authorized { api, credentials in try await api.avatar(user: user, using: credentials) }
            try check(generation)
            return result.id == asset ? result.jpeg : nil
        }
        try check(generation)
        guard avatarScope == scope else { throw CancellationError() }
        return image
    }
    @discardableResult
    private func invalidateAvatars() -> Task<Void, Never>? {
        guard let owner = stored?.userID ?? profile?.userID else { return nil }
        for session in Self.instances.compactMap(\.value)
            where session.store.environmentID == store.environmentID && (session.stored?.userID ?? session.profile?.userID) == owner {
            session.avatarsSuspended = true
        }
        return AccountAvatarLoader.invalidate(scope: .init(environment: store.environmentID, user: owner))
    }
    private func drainRevocations() async {
        guard let api = service?.api, let queue = try? store.revocations() else { return }
        var remaining: [LogoutRevocation] = []
        for ticket in queue where ticket.expiresAt > Date() {
            do { try await api.executeLogoutRevocation(ticket) }
            catch { remaining.append(ticket) }
        }
        try? store.saveRevocations(remaining)
    }
    #if DEBUG
    func installDebugProfile(long: Bool = false, offline: Bool = false) {
        profile = AccountProfile(userID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            accountName: "fictional_user", nickname: long ? String(repeating: "AzureFish ", count: 8) : "小鱼",
            bio: long ? String(repeating: "A long profile. ملف شخصي. 個人資料。", count: 12) : "", version: 1)
        connectivity = offline ? .offline : .online; avatarsSuspended = false; phase = .signedIn
    }
    #endif

    deinit { managerObservation?.cancel(); renewalTask?.cancel(); pathMonitor?.cancel() }

    private func isTerminal(_ error: Error) -> Bool {
        if let error = error as? AccountFailure, error == .expired { return true }
        if case APIClientError.service(let failure) = error {
            return [.unauthenticated, .refreshReplay, .refreshSuperseded, .authAttemptExpired].contains(failure.code)
        }
        return false
    }
}
