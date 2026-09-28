import Foundation
import AzureFishAPI

/// 协调单个应用会话的恢复、刷新、资料和退出，拒绝已退出代次的迟到响应。
@MainActor
final class SessionCoordinator {
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
    private var exitPending = false
    private var pendingLogout: LogoutRevocation?
    private var requests: [UUID: () -> Void] = [:]

    init(service: (any AccountServicing)?, store: CredentialStore, repository: UserRepository) {
        self.service = service; self.store = store; self.repository = repository
        sessionManager = service.map { APISessionManager(api: $0.api, store: KeychainAPISessionStore(store: store)) }
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
            stored = try store.load()
            try await sessionManager?.restore()
            stored = try store.load()
            guard let stored else { phase = .welcome; await drainRevocations(); return }
            phase = .restoring; publish()
            let credentials = try stored.credentials()
            guard credentials.refreshExpiresAt > Date() else { throw AccountFailure.expired }
            if stored.pendingRefreshID != nil || credentials.accessExpiresAt <= Date() { _ = try await refresh() }
            try await reloadProfile()
            phase = .signedIn
            await drainRevocations()
        } catch {
            noticeKey = AccountFailure.key(for: error)
            if isTerminal(error) {
                do { try await sessionManager?.clearLocalSession(); stored = nil; profile = nil; phase = .welcome }
                catch { phase = .recovery; noticeKey = AccountFailure.storage.key }
            } else {
                do {
                    if let user = stored?.userID, let cached = try repository.load(user: user) {
                        profile = cached; readOnly = true; phase = .signedIn
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
        authentication = nil; phase = .signedIn
    }
    /// 放弃表单时废弃当前代次；已发出请求可能在服务端完成，但不会安装迟到会话。
    func cancelAuthentication() {
        epoch = UUID(); authentication = nil
    }
    private func install(_ result: AuthenticatedSession) async throws {
        let value = StoredSession(result.credentials)
        try await sessionManager?.install(result.credentials)
        stored = value
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
            try store.clear(); phase = .welcome; profile = nil; stored = nil; publish(); return
        }
        busy = true
        defer { busy = false; exitPending = false; publish() }
        if !localOnly && (stored?.pendingRefreshID != nil || credentials.accessExpiresAt <= Date()) {
            credentials = try await refresh()
            pendingLogout = nil
        }
        exitPending = true; epoch = UUID(); refreshTask?.cancel()
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
        try await sessionManager?.clearLocalSession()
        stored = nil; profile = nil; authentication = nil; profileOperation = nil; pendingLogout = nil
        readOnly = false; noticeKey = nil; phase = .welcome
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
        readOnly = offline; phase = .signedIn
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
