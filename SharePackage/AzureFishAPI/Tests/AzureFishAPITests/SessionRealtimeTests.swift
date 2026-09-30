import Foundation
import Testing
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol
@testable import AzureFishAPI

/// 仅测试使用；生产模块不导出内存存储。
actor MemorySessionStore: APISessionStore {
    /// 按环境保存的虚构会话记录，初始为空。
    var records: [String: APISessionRecord] = [:]
    /// 成功保存的记录历史，按调用顺序排列。
    var writes: [APISessionRecord] = []
    /// 是否使下一次保存失败；失败后重置为 false。
    var failNextSave = false
    /// 指定应保存失败的刷新代次；nil 表示不按代次注入失败。
    var failGeneration: Int64?
    /// 读取指定环境的内存记录，没有记录时返回 nil。
    func load(environmentID: String) async throws -> APISessionRecord? { records[environmentID] }
    /// 按测试开关注入失败，否则保存完整记录并追加写入历史。
    func save(_ record: APISessionRecord, environmentID: String) async throws {
        if failNextSave || failGeneration == record.credentials.refreshGeneration {
            failNextSave = false; throw APISessionError.storageFailure
        }
        records[environmentID] = record; writes.append(record)
    }
    /// 删除指定环境的内存记录，保留写入历史用于断言。
    func clear(environmentID: String) async throws { records.removeValue(forKey: environmentID) }
    /// 设置按刷新代次触发的保存失败；nil 清除此故障条件。
    func fail(generation: Int64?) { failGeneration = generation }
}

private struct SessionFixture: Sendable {
    /// 此测试夹具生成的虚构用户、安装和会话 UUID。
    let user = UUID(), device = UUID(), session = UUID()
    /// 使用 example.invalid 的虚构 HTTPS 测试环境。
    let environment = try! APIEnvironment(identifier: "test", baseURL: URL(string: "https://example.invalid")!)
    /// 构造指定刷新代次的虚构凭据，默认代次为 1。
    func credentials(_ generation: Int64 = 1) throws -> SessionCredentials {
        try SessionCredentials(environmentID: "test", userID: user, deviceID: device, sessionID: session,
            accessToken: SessionToken(rawValue: String(repeating: generation == 1 ? "a" : "b", count: 43)),
            accessExpiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            refreshToken: SessionToken(rawValue: String(repeating: generation == 1 ? "r" : "s", count: 43)),
            refreshExpiresAt: Date(timeIntervalSince1970: 1_902_000_000), refreshGeneration: generation)
    }
    /// 构造与夹具用户身份一致的虚构 Protobuf 资料。
    func profile() -> AzureFishProtocol.UserProfile {
        var profile = AzureFishProtocol.UserProfile()
        profile.userID = user.uuidString.lowercased(); profile.accountName = "fictional_user"
        profile.nickname = "虚构"; profile.profileVersion = 1
        profile.createdAtMs = 1_800_000_000_000; profile.updatedAtMs = profile.createdAtMs
        return profile
    }
    /// 编码代次 2 的虚构认证响应，用于模拟成功刷新。
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
    /// 将虚构资料编码为 200 Protobuf 响应。
    func profileResponse() throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try profile().serializedData())
    }
}
/// 编码指定状态及错误码的虚构服务端错误响应。
private func failure(_ code: String = "UNAUTHENTICATED", status: Int = 401) throws -> HTTPResponse {
    var error = ApiError(); error.code = code
    return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/protobuf"], body: try error.serializedData())
}
/// 以 2 毫秒间隔最多检查条件 1500 次；仍未满足时抛出 requestTimeout。
private func until(_ condition: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<1500 { if await condition() { return }; try await Task.sleep(nanoseconds: 2_000_000) }
    throw WebSocketError.requestTimeout
}
private actor Gate {
    /// 屏障是否已释放；释放后后续 wait 直接返回。
    private var open = false
    /// 尚未释放的多个等待者，本测试屏障不单独处理取消。
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 等待测试显式 release；已经释放时直接返回。
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    /// 打开屏障并恢复全部等待者；重复调用不会再次恢复。
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}

@Suite("共享会话与实时提示", .timeLimit(.minutes(1)))
struct SessionRealtimeTests {
    /// 验证刷新被明确拒绝后所有消费者收到重新认证状态。
    @Test func rejectedRefreshPublishesReauthenticationToAllConsumers() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let transport = MockHTTPTransport { _, _ in try failure() }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        await #expect(throws: (any Error).self) { try await manager.refresh() }
        #expect(await manager.state.requiresReauthentication)
        await #expect(throws: APISessionError.verificationRequired) { try await manager.credentials() }
        try await manager.clearLocalSession()
        #expect(await store.records.isEmpty)
        try await manager.install(fixture.credentials())
        #expect(try await manager.credentials().userID == fixture.user)
    }

    /// 验证本地到期判断触发服务端确认而不直接丢弃会话。
    @Test func localClockExpiryRequestsServerConfirmationInsteadOfDiscardingSession() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let transport = MockHTTPTransport { request, _ in
            request.url.path.hasSuffix("refresh") ? try fixture.auth() : try fixture.profileResponse()
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        try await manager.install(fixture.credentials())
        #expect(try await manager.validateSession(now: Date(timeIntervalSince1970: 2_000_000_000)).userID == fixture.user)
        #expect(await manager.state.refreshGeneration == 2)
        #expect(await transport.requests.filter { $0.url.path.hasSuffix("refresh") }.count == 1)
    }

    /// 验证本地恢复不发送未决刷新，验证期间业务请求受阻。
    @Test func localRestoreDoesNotSendPendingRefreshAndBlocksBusinessRequests() async throws {
        let fixture = SessionFixture(), store = MemorySessionStore()
        let operation = UUID()
        try await store.save(.init(credentials: fixture.credentials(), pendingRefreshOperationID: operation), environmentID: "test")
        let transport = MockHTTPTransport { request, _ in
            request.url.path.hasSuffix("refresh") ? try fixture.auth() : try fixture.profileResponse()
        }
        let manager = APISessionManager(api: AccountAPI(environment: fixture.environment, transport: transport), store: store)
        await manager.setNetworkAccessAllowed(false)
        try await manager.restoreLocal()
        #expect(await transport.requests.isEmpty)
        #expect(try await manager.localIdentity().userID == fixture.user)
        await #expect(throws: APISessionError.verificationRequired) { try await manager.profile() }
        #expect(try await manager.validateSession().userID == fixture.user)
        let requests = await transport.requests
        #expect(requests.filter { $0.url.path.hasSuffix("refresh") }.count == 1)
        #expect(try RefreshRequest(serializedBytes: requests[0].body!).operationID == operation.uuidString.lowercased())
        await #expect(throws: APISessionError.verificationRequired) { try await manager.credentials() }
        await manager.setNetworkAccessAllowed(true)
        #expect(try await manager.profile().userID == fixture.user)
    }

    /// 验证并发 HTTP 和 WebSocket 认证确认共享同一次刷新。
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

    /// 验证刷新响应丢失后恢复原操作身份及请求字节。
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

    /// 验证新凭据保存失败时不发布新刷新代次。
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

    /// 验证迟到 401 使用已经更新的凭据而不再次刷新。
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

    /// 验证刷新期间清理会话不会被迟到响应恢复。
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

    /// 验证只有明确未认证错误触发刷新。
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

    /// 验证实时提示、凭据轮换及本地退出正确协调。
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

    /// 验证替换会话后拒绝旧刷新结果并保护新持久记录。
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

    /// 验证过期会话退出至多刷新一次且不重新发布登录状态。
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

    /// 验证离线确认失败及畸形提示不会误触发刷新。
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

    /// 验证策略关闭先通过 HTTP 确认认证失败再刷新。
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
