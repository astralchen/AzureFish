import Foundation
import Testing
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol
@testable import AzureFishAPI

/// 仅测试使用；生产模块不导出内存存储。
actor MemorySessionStore: APISessionStore {
    var records: [String: APISessionRecord] = [:]
    var writes: [APISessionRecord] = []
    var failNextSave = false
    var failGeneration: Int64?
    func load(environmentID: String) async throws -> APISessionRecord? { records[environmentID] }
    func save(_ record: APISessionRecord, environmentID: String) async throws {
        if failNextSave || failGeneration == record.credentials.refreshGeneration {
            failNextSave = false; throw APISessionError.storageFailure
        }
        records[environmentID] = record; writes.append(record)
    }
    func clear(environmentID: String) async throws { records.removeValue(forKey: environmentID) }
    func fail(generation: Int64?) { failGeneration = generation }
}

private struct SessionFixture: Sendable {
    let user = UUID(), device = UUID(), session = UUID()
    let environment = try! APIEnvironment(identifier: "test", baseURL: URL(string: "https://example.invalid")!)
    func credentials(_ generation: Int64 = 1) throws -> SessionCredentials {
        try SessionCredentials(environmentID: "test", userID: user, deviceID: device, sessionID: session,
            accessToken: SessionToken(rawValue: String(repeating: generation == 1 ? "a" : "b", count: 43)),
            accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            refreshToken: SessionToken(rawValue: String(repeating: generation == 1 ? "r" : "s", count: 43)),
            refreshExpiresAt: Date(timeIntervalSince1970: 1_902_000_000), refreshGeneration: generation)
    }
    func profile() -> AzureFishProtocol.UserProfile {
        var profile = AzureFishProtocol.UserProfile()
        profile.userID = user.uuidString.lowercased(); profile.accountName = "fictional_user"
        profile.nickname = "虚构"; profile.profileVersion = 1
        profile.createdAtMs = 1_800_000_000_000; profile.updatedAtMs = profile.createdAtMs
        return profile
    }
    func auth() throws -> HTTPResponse {
        let credentials = try credentials(2)
        var message = AuthResponse()
        message.environmentID = "test"; message.userID = user.uuidString.lowercased()
        message.deviceID = device.uuidString.lowercased(); message.sessionID = session.uuidString.lowercased()
        message.accessToken = credentials.accessToken.rawValue; message.refreshToken = credentials.refreshToken.rawValue
        message.accessExpiresAtMs = 1_900_000_000_000; message.refreshExpiresAtMs = 1_902_000_000_000
        message.refreshGeneration = 2; message.profile = profile()
        return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try message.serializedData())
    }
    func profileResponse() throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try profile().serializedData())
    }
}
private func failure(_ code: String = "UNAUTHENTICATED", status: Int = 401) throws -> HTTPResponse {
    var error = ApiError(); error.code = code
    return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/protobuf"], body: try error.serializedData())
}
private func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1500 { if await condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    throw WebSocketError.requestTimeout
}
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

@Suite("共享会话与实时提示", .timeLimit(.minutes(1)))
struct SessionRealtimeTests {
    @Test func concurrentHTTPAndWebSocketConfirmationShareRefresh() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore(), gate = Gate()
        let transport = MockHTTPTransport { request, _ in
            if request.url.path == "/v1/auth/refresh" { await gate.wait(); return try fixture.auth() }
            if request.headers["Authorization"] == "Bearer \(try fixture.credentials().accessToken.rawValue)" { return try failure() }
            return try fixture.profileResponse()
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        let first = Task { try await manager.profile() }
        let second = Task { try await manager.confirmRealtimeAuthentication(using: fixture.credentials()) }
        try await until { await transport.requests.contains { $0.url.path == "/v1/auth/refresh" } }
        await gate.release()
        #expect(try await first.value.userID == fixture.user)
        #expect(try await second.value)
        #expect(await transport.requests.filter { $0.url.path == "/v1/auth/refresh" }.count == 1)
        #expect(await store.writes.map(\.pendingRefreshOperationID).compactMap { $0 }.count == 1)
        #expect(try await manager.credentials().refreshGeneration == 2)
    }

    @Test func refreshResponseLostRestoresSameIdentityAndBytes() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let lost = MockHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let first = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: lost), store: store)
        try await first.install(fixture.credentials())
        await #expect(throws: (any Error).self) { try await first.refresh() }
        let pending = try #require(await store.records["test"])
        #expect(pending.pendingRefreshOperationID != nil)
        let recovered = MockHTTPTransport { _, _ in try fixture.auth() }
        let restored = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: recovered), store: store)
        try await restored.restore()
        let original = try #require(await lost.requests.first), replay = try #require(await recovered.requests.first)
        #expect(original.body == replay.body)
        #expect(try await restored.credentials().refreshGeneration == 2)
        #expect(await store.records["test"]?.pendingRefreshOperationID == nil)
    }

    @Test func failedCredentialPersistenceDoesNotPublishNewGeneration() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let transport = MockHTTPTransport { _, _ in try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        await store.fail(generation: 2)
        await #expect(throws: APISessionError.storageFailure) { try await manager.refresh() }
        #expect(await manager.state.refreshGeneration == 1)
        #expect(await store.records["test"]?.pendingRefreshOperationID != nil)
        await store.fail(generation: nil)
        _ = try await manager.refresh()
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[0].body == requests[1].body)
    }

    @Test func stale401UsesAlreadyUpdatedCredentialsWithoutSecondRefresh() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore(), gate = Gate()
        let transport = MockHTTPTransport { request, _ in
            if request.url.path == "/v1/auth/refresh" { return try fixture.auth() }
            if request.headers["Authorization"] == "Bearer \(try fixture.credentials().accessToken.rawValue)" {
                await gate.wait(); return try failure()
            }
            return try fixture.profileResponse()
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        let old = Task { try await manager.profile() }
        try await until { await transport.requests.count == 1 }
        _ = try await manager.refresh()
        await gate.release()
        _ = try await old.value
        #expect(await transport.requests.filter { $0.url.path == "/v1/auth/refresh" }.count == 1)
    }

    @Test func clearDuringRefreshPreventsResurrection() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore(), gate = Gate()
        let transport = MockHTTPTransport { _, _ in await gate.wait(); return try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        let refresh = Task { try await manager.refresh() }
        try await until { await transport.requests.count == 1 }
        try await manager.clearLocalSession()
        await gate.release()
        await #expect(throws: (any Error).self) { try await refresh.value }
        #expect(await manager.state.sessionID == nil)
        #expect(await store.records["test"] == nil)
    }

    @Test(arguments: ["INVALID_CREDENTIALS", "UNKNOWN"])
    func onlyExplicitUnauthenticatedRefreshes(code: String) async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let transport = MockHTTPTransport { _, _ in try failure(code) }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        await #expect(throws: (any Error).self) { try await manager.profile() }
        #expect(await transport.requests.count == 1)
        #expect(await manager.state.sessionID == fixture.session)
    }

    @Test func realtimeHintsRotationAndLocalLogout() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let http = MockHTTPTransport { _, _ in try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: http), store: store)
        try await manager.install(fixture.credentials())
        let first = MockWebSocketTransport(), second = MockWebSocketTransport()
        let sockets = MockWebSocketFactory([first, second])
        let client = IMRealtimeClient(sessionManager: manager, transportFactory: sockets.make)
        var signals = await client.syncSignals().makeAsyncIterator()
        await client.start()
        try await until { await client.currentState == .connected }
        #expect(await signals.next()?.reason == .connected)
        var hint = IMSyncHint(); hint.epoch = UUID().uuidString; hint.latestCursor = "opaque-hint-not-checkpoint"
        await first.push(.success(.binary(try hint.serializedData())))
        let received = await signals.next()
        #expect(received?.hint?.cursor == hint.latestCursor)
        #expect(received?.session.sessionID == fixture.session)
        _ = try await manager.refresh()
        try await until { await second.handshakes.count == 1 }
        #expect(await second.handshakes.first?.headers["Authorization"] == "Bearer \(try fixture.credentials(2).accessToken.rawValue)")
        #expect(await first.closeCount > 0)
        try await manager.clearLocalSession()
        try await until { await client.currentState == .stopped }
        #expect(await second.closeCount > 0)
        await client.stop()
    }

    @Test func replacementRejectsOldRefreshAndProtectsStoredSession() async throws {
        let fixture = SessionFixture(), replacement = SessionFixture(), store = MemorySessionStore(), gate = Gate()
        let transport = MockHTTPTransport { _, _ in await gate.wait(); return try fixture.auth() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        let old = Task { try await manager.refresh() }
        try await until { await transport.requests.count == 1 }
        try await manager.install(replacement.credentials())
        await gate.release()
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(try await manager.credentials().sessionID == replacement.session)
        #expect(await store.records["test"]?.credentials.sessionID == replacement.session)
    }

    @Test func expiredLogoutRefreshesOnceWithoutRepublishingSession() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let transport = MockHTTPTransport { request, _ in
            if request.url.path == "/v1/auth/refresh" { return try fixture.auth() }
            if request.headers["Authorization"] == "Bearer \(try fixture.credentials().accessToken.rawValue)" { return try failure() }
            return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: Data())
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        try await manager.logout(operationID: UUID())
        #expect(await manager.state.sessionID == nil)
        #expect(await store.records["test"] == nil)
        let history = await transport.requests
        #expect(history.filter { $0.url.path == "/v1/auth/refresh" }.count == 1)
        let logout = history.filter { $0.url.path == "/v1/auth/logout" }
        #expect(logout.count == 2 && logout[0].body == logout[1].body)
    }

    @Test func offlineConfirmationAndMalformedHintDoNotRefresh() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let http = MockHTTPTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: http), store: store)
        try await manager.install(fixture.credentials())
        await #expect(throws: (any Error).self) { try await manager.confirmRealtimeAuthentication(using: fixture.credentials()) }
        #expect(await http.requests.allSatisfy { $0.url.path != "/v1/auth/refresh" })
        let transport = MockWebSocketTransport(), factory = MockWebSocketFactory([transport])
        let client = IMRealtimeClient(sessionManager: manager, transportFactory: factory.make)
        await client.start()
        try await until { await client.currentState == .connected }
        await transport.push(.success(.text("not a binary hint")))
        try await until { await client.currentState == .failed(.invalidHint) }
        #expect(factory.count == 1)
        #expect(await manager.state.sessionID == fixture.session)
        await client.stop()
    }

    @Test(arguments: [false, true])
    func policyCloseConfirmsHTTPBeforeRefresh(expired: Bool) async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let http = MockHTTPTransport { request, _ in
            if request.url.path == "/v1/auth/refresh" { return try fixture.auth() }
            return try expired ? failure() : fixture.profileResponse()
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: http), store: store)
        try await manager.install(fixture.credentials())
        let first = MockWebSocketTransport(), second = MockWebSocketTransport()
        let sockets = MockWebSocketFactory([first, second])
        let client = IMRealtimeClient(sessionManager: manager, transportFactory: sockets.make)
        await client.start()
        try await until { await client.currentState == .connected }
        await first.push(.failure(WebSocketError.closed(code: 1008)))
        if expired {
            try await until { await second.handshakes.count == 1 }
            #expect(await http.requests.filter { $0.url.path == "/v1/auth/refresh" }.count == 1)
        } else {
            try await until { await client.currentState == .failed(.policyClosed) }
            #expect(sockets.count == 1)
            #expect(await http.requests.count == 1)
        }
        await client.stop()
    }
}
