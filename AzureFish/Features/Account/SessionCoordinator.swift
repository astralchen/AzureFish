import Foundation
import CryptoKit
import AzureFishAPI
import UIKit

/// 协调单个应用会话的恢复、刷新、资料和退出，拒绝已退出代次的迟到响应。
@MainActor
final class SessionCoordinator {
    private final class WeakSession {
        weak var value: SessionCoordinator?
        init(_ value: SessionCoordinator) { self.value = value }
    }
    private static var instances: [WeakSession] = []
    enum Phase: Equatable { case restoring, welcome, signedIn, recovery }
    private(set) var phase: Phase = .restoring
    private(set) var profile: AccountProfile?
    private(set) var readOnly = false
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
    private var pendingLogout: LogoutRevocation?
    private var requests: [UUID: () -> Void] = [:]

    init(service: (any AccountServicing)?, store: CredentialStore, repository: UserRepository) {
        self.service = service; self.store = store; self.repository = repository
        sessionManager = service.map { APISessionManager(api: $0.api, store: KeychainAPISessionStore(store: store)) }
        Self.instances.removeAll { $0.value == nil }; Self.instances.append(WeakSession(self))
    }
    static func configured() -> SessionCoordinator {
        let service = LiveAccountService.configured()
        let keys = KeychainValueStore()
        let environment = service?.api.environment.identifier ?? "unconfigured"
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountProfiles", isDirectory: true)
        return SessionCoordinator(service: service, store: CredentialStore(values: keys, environmentID: environment),
            repository: UserRepository(root: root, keys: keys, environment: environment))
    }
    private func publish() { didChange?() }
    private func check(_ generation: UUID) throws {
        guard epoch == generation, !exitPending else { throw CancellationError() }
        try Task.checkCancellation()
    }
    func restore() async {
        guard !busy else { return }
        busy = true; noticeKey = nil; publish()
        defer { busy = false; publish() }
        guard service != nil else { phase = .welcome; noticeKey = AccountFailure.unavailable.key; return }
        do {
            try await recoverDeletionRequest()
            try await recoverLocalDeletion()
            stored = try store.load()
            try await sessionManager?.restore()
            stored = try store.load()
            guard let stored else { phase = .welcome; await drainRevocations(); return }
            phase = .restoring; publish()
            let credentials = try stored.credentials()
            guard credentials.refreshExpiresAt > Date() else { throw AccountFailure.expired }
            if stored.pendingRefreshID != nil || credentials.accessExpiresAt <= Date() { _ = try await refresh() }
            try await reloadProfile()
            avatarsSuspended = false; phase = .signedIn
            await drainRevocations()
        } catch {
            noticeKey = AccountFailure.key(for: error)
            if isTerminal(error) {
                invalidateAvatars()
                do { try await sessionManager?.clearLocalSession(); stored = nil; profile = nil; phase = .welcome }
                catch { phase = .recovery; noticeKey = AccountFailure.storage.key }
            } else {
                do {
                    if let user = stored?.userID, let cached = try repository.load(user: user) {
                        profile = cached; readOnly = true; avatarsSuspended = false; phase = .signedIn
                    } else { phase = .recovery }
                } catch { phase = .recovery; noticeKey = AccountFailure.key(for: error) }
            }
        }
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
        try await install(result)
        authentication = nil; avatarsSuspended = false; phase = .signedIn
    }
    /// 放弃表单时废弃当前代次；已发出请求可能在服务端完成，但不会安装迟到会话。
    func cancelAuthentication() {
        epoch = UUID(); authentication = nil
    }
    private func install(_ result: AuthenticatedSession) async throws {
        let value = StoredSession(result.credentials)
        if stored?.userID != value.userID { await invalidateAvatars()?.value }
        try await sessionManager?.install(result.credentials)
        stored = value
        avatarsSuspended = false
        acceptProfile(AccountProfile(result.profile))
        readOnly = false
    }
    private func acceptProfile(_ value: AccountProfile) {
        guard stored?.userID == value.userID else { return }
        if let profile, profile.userID == value.userID, profile.version > value.version { return }
        profile = value
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
            if isTerminal(error), !exitPending {
                invalidateAvatars()
                epoch = UUID(); refreshTask?.cancel()
                profile = nil; readOnly = false
                do { try await sessionManager?.clearLocalSession(); stored = nil; phase = .welcome; noticeKey = AccountFailure.expired.key }
                catch { phase = .recovery; noticeKey = AccountFailure.storage.key }
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
        acceptProfile(AccountProfile(value)); readOnly = false; publish()
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
    func logout(localOnly: Bool = false) async throws {
        guard !busy else { throw AccountFailure.busy }
        stored = try store.load()
        guard let api = service?.api, var credentials = try stored?.credentials() else {
            await invalidateAvatars()?.value
            try store.clear(); phase = .welcome; profile = nil; stored = nil; publish(); return
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
        if !localOnly && (stored?.pendingRefreshID != nil || credentials.accessExpiresAt <= Date()) {
            credentials = try await refresh()
            pendingLogout = nil
        }
        exitPending = true; epoch = UUID(); refreshTask?.cancel()
        await invalidateAvatars()?.value
        requests.values.forEach { $0() }; requests.removeAll()
        let ticket = try pendingLogout ?? api.prepareLogoutRevocation(operationID: UUID(), using: credentials)
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
        readOnly = false; noticeKey = nil; phase = .welcome
    }
    func securityInfo() async throws -> AccountSecurityInfo {
        try await authorized { api, credentials in try await api.security(using: credentials) }
    }
    /// 网络重试复用原敏感操作；服务端撤销当前会话后不自动刷新凭据。
    func performSecurity(_ action: AccountSecurityAction, password: String, newPassword: String = "") async throws {
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
        stored = nil; profile = nil; readOnly = false; phase = .welcome
        noticeKey = action == .deleteAccount ? "account.deletion.accepted" : "account.security.completed"
    }
    private func endOtherWindows(user: UUID) async throws {
        for other in Self.instances.compactMap(\.value) where other !== self && other.store.environmentID == store.environmentID && other.profile?.userID == user {
            other.invalidateAvatars()
            other.epoch = UUID(); other.requests.values.forEach { $0() }; other.requests.removeAll()
            other.refreshTask?.cancel(); other.profile = nil; other.stored = nil
            other.avatarOperation = nil; other.securityOperation = nil
            other.authentication = nil; other.profileOperation = nil; other.readOnly = false
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
        try store.values.remove(deletionRequestKey)
        try store.values.remove(deletionKey)
    }
    func updateAvatar(_ jpeg: Data) async throws {
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
        readOnly = offline; avatarsSuspended = false; phase = .signedIn
    }
    #endif

    private func isTerminal(_ error: Error) -> Bool {
        if let error = error as? AccountFailure, error == .expired { return true }
        if case APIClientError.service(let failure) = error {
            return [.unauthenticated, .refreshReplay, .refreshSuperseded].contains(failure.code)
        }
        return false
    }
}
