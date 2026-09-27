import Foundation
import Testing
import AzureFishAPI
import AzureFishNetwork
import AzureFishProtocol
import SwiftProtobuf
@testable import AzureFish

actor AccountTestTransport: HTTPTransport {
    var requests: [HTTPRequest] = []
    var offline = false
    var conflict = false
    var slow = false
    var unauthorized = false
    func setUnauthorized(_ value: Bool) { unauthorized = value }
    func setOffline(_ value: Bool) { offline = value }
    func setConflict(_ value: Bool) { conflict = value }
    func setSlow(_ value: Bool) { slow = value }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if slow { try await Task.sleep(nanoseconds: 100_000_000) }
        if offline { throw URLError(.notConnectedToInternet) }
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

@Suite("会话协调器")
@MainActor
struct SessionCoordinatorTests {
    private func fixture(_ transport: AccountTestTransport, keys: MemorySecureValues) throws -> (SessionCoordinator, CredentialStore, URL) {
        let store = CredentialStore(values: keys, environmentID: "local-development")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = LiveAccountService(api: AccountAPI(environment: try APIEnvironment.localTesting(), transport: transport))
        return (SessionCoordinator(service: service, store: store, repository: UserRepository(root: root, keys: keys, environment: "local-development")), store, root)
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
    @Test func pendingRefreshResumesSameIDAndConcurrentReadsShareRotation() async throws {
        let transport = AccountTestTransport(); await transport.setSlow(true)
        let (coordinator, store, root) = try fixture(transport, keys: MemorySecureValues())
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try store.save(StoredSession(sampleCredentials(accessExpired: true), pendingRefreshID: id))
        let restoration = Task { await coordinator.restore() }
        while await transport.requests.isEmpty { await Task.yield() }
        async let a: Void = coordinator.reloadProfile()
        async let b: Void = coordinator.reloadProfile()
        try await a; try await b; await restoration.value
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
}
