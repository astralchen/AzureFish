import Foundation
import Testing
import AzureFishAPI
import AzureFishNetwork
import AzureFishProtocol
import SwiftProtobuf
import UIKit
@testable import AzureFish

actor AccountTestTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var offline = false
    var conflict = false
    var slow = false
    var unauthorized = false
    var logoutOffline = false
    var logoutNeedsRefresh = false
    func setLogoutOffline(_ value: Bool) { logoutOffline = value }
    func setLogoutNeedsRefresh(_ value: Bool) { logoutNeedsRefresh = value }
    func setUnauthorized(_ value: Bool) { unauthorized = value }
    func setOffline(_ value: Bool) { offline = value }
    func setConflict(_ value: Bool) { conflict = value }
    func setSlow(_ value: Bool) { slow = value }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if slow { try await Task.sleep(nanoseconds: 100_000_000) }
        if offline { throw URLError(.notConnectedToInternet) }
        if request.url.path.hasSuffix("logout") {
            if logoutNeedsRefresh && request.headers["Authorization"] == "Bearer " + String(repeating: "a", count: 43) {
                var failure = ApiError(); failure.code = "UNAUTHENTICATED"
                return HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/protobuf"], body: try failure.serializedData())
            }
            if logoutOffline { throw URLError(.notConnectedToInternet) }
        }
        if unauthorized {
            var failure = ApiError(); failure.code = "UNAUTHENTICATED"
            return HTTPResponse(statusCode: 401, headers: ["Content-Type": "application/protobuf"], body: try failure.serializedData())
        }
        let credentials = try sampleCredentials()
        var profile = AzureFishProtocol.UserProfile()
        profile.userID = credentials.userID.uuidString.lowercased(); profile.accountName = "fictional_user"
        profile.nickname = "Fictional"; profile.profileVersion = conflict ? 2 : 1
        profile.createdAtMs = 1_800_000_000_000; profile.updatedAtMs = 1_800_000_000_000
        if request.method == .patch {
            if conflict {
                var failure = ApiError(); failure.code = "PROFILE_VERSION_CONFLICT"
                return HTTPResponse(statusCode: 409, headers: ["Content-Type": "application/protobuf"], body: try failure.serializedData())
            }
            let change = try UpdateProfileRequest(serializedBytes: request.body!)
            if change.hasNickname { profile.nickname = change.nickname }
            if change.hasBio { profile.bio = change.bio }
            profile.profileVersion = change.expectedProfileVersion + 1
        }
        if request.url.path.hasSuffix("logout") {
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: Data())
        }
        if request.url.path.hasSuffix("me") {
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try profile.serializedData())
        }
        var auth = AuthResponse()
        auth.environmentID = credentials.environmentID; auth.userID = credentials.userID.uuidString.lowercased()
        auth.deviceID = credentials.deviceID.uuidString.lowercased(); auth.sessionID = credentials.sessionID.uuidString.lowercased()
        auth.accessToken = String(repeating: "b", count: 43); auth.refreshToken = String(repeating: "s", count: 43)
        auth.accessExpiresAtMs = 2_000_000_000_000; auth.refreshExpiresAtMs = 2_002_000_000_000
        auth.refreshGeneration = request.url.path.hasSuffix("refresh") ? 2 : 1; auth.profile = profile
        if request.url.path.hasSuffix("login") { auth.deviceID = try LoginRequest(serializedBytes: request.body!).deviceID }
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try auth.serializedData())
    }
}

@Suite("会话协调器", .serialized)
@MainActor
struct SessionCoordinatorTests {
    private func fixture(_ transport: AccountTestTransport, keys: MemorySecureValues, cached: Bool = true) throws -> (SessionCoordinator, CredentialStore, URL) {
        let store = CredentialStore(values: keys, environmentID: "local-development")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LiveAccountService(api: AccountAPI(environment: try APIEnvironment.localTesting(), transport: transport))
        let repository = UserRepository(root: root, keys: keys, environment: "local-development")
        if cached {
            try repository.save(AccountProfile(userID: sampleCredentials().userID, accountName: "fictional_user",
                nickname: "Fictional", bio: "", version: 1))
        }
        return (SessionCoordinator(service: service, store: store, repository: repository), store, root)
    }
    @Test func cachedColdStartPublishesBeforeNetworkValidationAndPreservesIdentity() async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (first, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await first.restore()
        let second = SessionCoordinator(service: first.service, store: store,
            repository: UserRepository(root: root, keys: keys, environment: "local-development"))
        await transport.setSlow(true)
        var states: [(SessionCoordinator.Phase, SessionCoordinator.Connectivity)] = []
        second.didChange = { states.append((second.phase, second.connectivity)) }
        await second.restore()
        #expect(states.contains { $0.0 == .signedIn && $0.1 == .checking })
        #expect(second.connectivity == .online && second.profile == first.profile)
        #expect(second.rememberedAccount?.accountName == "fictional_user")
        #expect(!second.canCreateBusinessCache)
        await transport.setOffline(true)
        await second.restore()
        #expect(second.phase == .signedIn && second.connectivity == .offline)
        await #expect(throws: APISessionError.verificationRequired) { try await second.sessionManager!.credentials() }
        await transport.setOffline(false)
        await second.restore()
        #expect(second.connectivity == .online)
        second.didChange = nil
    }

    @Test func localLogoutRetainsAccountHintButNeverRestoresAuthentication() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let hint = coordinator.rememberedAccount
        try await coordinator.logout(localOnly: true)
        await coordinator.restore()
        #expect(coordinator.phase == .welcome && coordinator.profile == nil)
        #expect(coordinator.rememberedAccount == hint && hint != nil)
        #expect(try store.load() == nil)
        try store.forgetAccount(user: hint!.userID)
        #expect(coordinator.rememberedAccount == nil)
    }

    @Test func damagedProfileNeverBecomesAnEmptyAuthenticatedProfile() async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (coordinator, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        for key in keys.data.keys where key.hasPrefix("profile-key.") { keys.data[key] = nil }
        await coordinator.restore()
        #expect(coordinator.phase == .recovery && coordinator.profile == nil)
        #expect(try store.load() != nil)
    }

    @Test(arguments: [false, true]) func noCacheRequiresRecoveryEvenWhenOnline(offline: Bool) async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues(), cached: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await transport.setOffline(offline)
        await coordinator.restore()
        #expect(coordinator.phase == .recovery && coordinator.profile == nil)
        #expect(try store.load() != nil)
        #expect(await transport.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rejectedRefreshReturnsToWelcomeAndClearsSession() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        await transport.setUnauthorized(true)
        await #expect(throws: (any Error).self) { try await coordinator.reloadProfile() }
        #expect(coordinator.phase == .welcome && coordinator.profile == nil)
        #expect(try store.load() == nil)
    }
    @Test func rejectedRefreshDuringProfileWriteStillClearsSession() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let base = try #require(coordinator.profile)
        await transport.setUnauthorized(true)
        await #expect(throws: (any Error).self) {
            try await coordinator.saveProfile(base: base, nickname: "Draft", bio: "")
        }
        #expect(coordinator.phase == .welcome && coordinator.profile == nil)
        #expect(try store.load() == nil)
    }
    @Test func pendingRefreshResumesSameIDAndConcurrentReadsShareRotation() async throws {
        let transport = AccountTestTransport(); await transport.setSlow(true)
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.save(StoredSession(sampleCredentials(accessExpired: true), pendingRefreshID: id))
        let restoration = Task { await coordinator.restore() }
        while await transport.requests.isEmpty { await Task.yield() }
        async let a = coordinator.sessionManager!.refresh()
        async let b = coordinator.sessionManager!.refresh()
        _ = try await a; _ = try await b; await restoration.value
        let requests = await transport.requests.filter { $0.url.path.hasSuffix("refresh") }
        #expect(requests.count == 1)
        #expect(try RefreshRequest(serializedBytes: requests[0].body!).operationID == id.uuidString.lowercased())
        #expect(try store.load()?.pendingRefreshID == nil)
        #expect(try store.load()?.credentials().refreshGeneration == 2)
    }
    @Test func localLogoutQueuesOriginalAccessOnlyAndCannotRestoreLogin() async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (coordinator, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        await transport.setOffline(true)
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        let firstBody = await transport.requests.last?.body
        try await coordinator.logout(localOnly: true)
        #expect(coordinator.phase == .welcome && coordinator.profile == nil)
        #expect(try store.load() == nil)
        let tickets = try store.revocations()
        #expect(tickets.count == 1)
        let encoded = try JSONEncoder().encode(tickets)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(String(repeating: "r", count: 43)))
        await transport.setOffline(false)
        await coordinator.restore()
        let last = await transport.requests.last
        #expect(last?.body == firstBody)
        #expect(try store.revocations().isEmpty)
        #expect(coordinator.phase == .welcome)
    }
    @Test func conflictKeepsServerLatestAndDoesNotResubmitDraft() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let base = try #require(coordinator.profile)
        await transport.setConflict(true)
        await #expect(throws: AccountFailure.conflict) { try await coordinator.saveProfile(base: base, nickname: "Draft", bio: "") }
        #expect(coordinator.profile?.version == 2)
        #expect(coordinator.profile?.nickname == "Fictional")
        #expect(await transport.requests.filter { $0.method == .patch }.count == 1)
    }
    @Test func cancellationDuringCredentialWriteRemovesLateStoredSession() async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (coordinator, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.restore()
        keys.onWrite = { [weak coordinator] key in
            if key.hasPrefix("session.") { coordinator?.cancelAuthentication() }
        }
        let input = AuthenticationInput(register: false, account: "fictional", password: "Fictional-Password-123", nickname: "")
        await #expect(throws: CancellationError.self) { try await coordinator.authenticate(input) }
        #expect(coordinator.phase == .welcome && coordinator.profile == nil)
        #expect(try store.load() == nil)
        keys.onWrite = nil
        await coordinator.restore()
        #expect(coordinator.phase == .welcome)
    }

    @Test func cancelledLoginCannotInstallLateResponse() async throws {
        let transport = AccountTestTransport(); await transport.setSlow(true)
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        await coordinator.restore()
        let input = AuthenticationInput(register: false, account: "fictional", password: "Fictional-Password-123", nickname: "")
        let task = Task { try await coordinator.authenticate(input) }
        while await transport.requests.isEmpty { await Task.yield() }
        coordinator.cancelAuthentication()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.load() == nil)
        #expect(coordinator.phase == .welcome)
    }
    @Test func offlineRestorationRequiresCurrentAccountSnapshot() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        await transport.setOffline(true)
        await coordinator.restore()
        #expect(coordinator.phase == .signedIn && coordinator.readOnly)
        #expect(coordinator.profile?.accountName == "fictional_user")
    }

    @Test(arguments: ["valid", "revoked", "offline", "storage"])
    func failedLogoutRequiresValidationBeforeBusinessAccess(recovery: String) async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (coordinator, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let profile = try #require(coordinator.profile), identity = coordinator.sessionIdentity
        let snapshot = keys.data
        await transport.setLogoutOffline(true)
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        #expect(coordinator.phase == .signedIn && coordinator.connectivity == .offline)
        #expect(coordinator.profile == profile && coordinator.sessionIdentity == identity)
        #expect(keys.data == snapshot)
        let sent = await transport.requests.count
        await #expect(throws: AccountFailure.offline) {
            try await coordinator.saveProfile(base: profile, nickname: "Draft", bio: "")
        }
        await #expect(throws: (any Error).self) { try await coordinator.reloadProfile() }
        #expect(await transport.requests.count == sent)
        await transport.setOffline(recovery == "offline")
        await transport.setUnauthorized(recovery == "revoked")
        keys.failReads = recovery == "storage"
        await coordinator.restore()
        keys.failReads = false
        if recovery == "valid" {
            #expect(coordinator.phase == .signedIn && !coordinator.readOnly)
            #expect(coordinator.sessionIdentity == identity)
            try await coordinator.reloadProfile()
        } else if recovery == "revoked" {
            #expect(coordinator.phase == .welcome && coordinator.profile == nil)
            #expect(try store.load() == nil)
        } else {
            #expect(coordinator.readOnly)
            #expect(try store.load() != nil)
            #expect(coordinator.phase == (recovery == "storage" ? .recovery : .signedIn))
            #expect(await transport.requests.filter { $0.method == .patch }.isEmpty)
            await transport.setOffline(false)
            await coordinator.restore()
            #expect(coordinator.phase == .signedIn && !coordinator.readOnly)
        }
    }

    @Test func retryLogoutUsesSameOperationAndManagerRefreshDespiteExpiredLocalCredential() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        await transport.setLogoutOffline(true)
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        let first = try #require(await transport.requests.last)
        // 协调器读到过期记录时，也不能对 endingSession 管理器执行预刷新。
        try store.save(StoredSession(sampleCredentials(accessExpired: true)))
        await transport.setLogoutOffline(false)
        await transport.setLogoutNeedsRefresh(true)
        try await coordinator.logout()
        let requests = await transport.requests
        let exits = requests.filter { $0.url.path.hasSuffix("logout") }
        #expect(exits.count == 3 && exits.allSatisfy { $0.body == first.body })
        #expect(exits.last?.headers["Authorization"] == "Bearer " + String(repeating: "b", count: 43))
        #expect(requests.filter { $0.url.path.hasSuffix("refresh") }.count == 1)
        #expect(coordinator.phase == .welcome)
        #expect(try store.load() == nil)
    }

    @Test func localLogoutAfterRotationQueuesCurrentBearerAndRetainsOperation() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        await transport.setLogoutNeedsRefresh(true)
        await transport.setLogoutOffline(true)
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        let first = try #require(await transport.requests.first { $0.url.path.hasSuffix("logout") })
        #expect(try store.load()?.credentials().refreshGeneration == 2)
        try await coordinator.logout(localOnly: true)
        #expect(coordinator.phase == .welcome)
        #expect(try store.load() == nil)
        let ticket = try #require(try store.revocations().first)
        await transport.setLogoutOffline(false)
        await coordinator.restore()
        let last = try #require(await transport.requests.last)
        #expect(last.body == first.body)
        #expect(last.headers["Authorization"] == "Bearer " + String(repeating: "b", count: 43))
        #expect(ticket.operationID.uuidString.lowercased() == (try LogoutRequest(serializedBytes: first.body!)).operationID)
        #expect(coordinator.phase == .welcome)
        #expect(try store.revocations().isEmpty)
    }

    @Test func logoutStorageFailureKeepsPageReadOnlyAndCredentialsRecoverable() async throws {
        let transport = AccountTestTransport(), keys = MemorySecureValues()
        let (coordinator, store, root) = try fixture(transport, keys: keys)
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let identity = coordinator.sessionIdentity
        keys.failWrites = true
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        #expect(coordinator.phase == .signedIn && coordinator.readOnly)
        #expect(coordinator.sessionIdentity == identity)
        #expect(try store.load() != nil)
        keys.failWrites = false
        await transport.setUnauthorized(true)
        await coordinator.restore()
        #expect(coordinator.phase == .welcome)
        #expect(try store.load() == nil)
    }

    @Test func readonlyProfileReloadRecoversInPlaceAndPreservesEditorDraft() async throws {
        let transport = AccountTestTransport()
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(StoredSession(sampleCredentials()))
        await coordinator.restore()
        let profile = ProfileViewController(session: coordinator)
        let editor = EditProfileViewController(session: coordinator, profile: try #require(coordinator.profile))
        let navigation = AppNavigationController(rootViewController: profile)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        window.rootViewController = navigation; window.makeKeyAndVisible(); window.layoutIfNeeded()
        navigation.pushViewController(editor, animated: false); window.layoutIfNeeded()
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let nickname = try #require(descendants(editor.view).compactMap { $0 as? UITextField }
            .first { $0.accessibilityIdentifier == "account.profile.nickname" })
        let bio = try #require(descendants(editor.view).compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "account.profile.bio" })
        let save = try #require(descendants(editor.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "account.design.save" })
        nickname.text = "Unsubmitted"; bio.text = "Draft survives reconnect"
        await transport.setLogoutOffline(true)
        await #expect(throws: (any Error).self) { try await coordinator.logout() }
        #expect(!save.isEnabled && navigation.topViewController === editor)
        let menu = try #require(descendants(profile.view).compactMap { $0 as? ProfileMenuView }.first)
        menu.didSelect?("account.design.reload")
        for _ in 0..<1_000 where menu.isReloading { try await Task.sleep(nanoseconds: 2_000_000) }
        #expect(!menu.isReloading && !coordinator.readOnly && save.isEnabled)
        #expect(navigation.viewControllers.count == 2 && navigation.topViewController === editor)
        #expect(nickname.text == "Unsubmitted" && bio.text == "Draft survives reconnect")
        #expect(await transport.requests.filter { $0.method == .patch }.isEmpty)
    }
}
