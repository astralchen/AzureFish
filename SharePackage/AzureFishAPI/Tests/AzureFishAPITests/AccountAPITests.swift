import AzureFishAPI
import AzureFishNetwork
import AzureFishNetworkTestSupport
import AzureFishProtocol
import Foundation
import Testing

/// 账号 API 测试共用的虚构用户 UUID。
private let testUserID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
/// 账号 API 测试共用的虚构安装 UUID。
private let testDeviceID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
/// 账号 API 测试共用的虚构会话 UUID。
private let testSessionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!

/// 创建指向 example.invalid 的指定名称测试环境。
private func environment(_ name: String = "test") throws -> APIEnvironment {
    try APIEnvironment(identifier: name, baseURL: URL(string: "https://example.invalid")!)
}

/// 按给定身份及刷新代次构造虚构凭据，不访问安全存储。
private func credentials(generation: Int64 = 1, userID: UUID = testUserID, sessionID: UUID = testSessionID) throws -> SessionCredentials {
    try SessionCredentials(environmentID: "test", userID: userID, deviceID: testDeviceID, sessionID: sessionID,
        accessToken: SessionToken(rawValue: String(repeating: generation == 1 ? "a" : "b", count: 43)),
        accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_900),
        refreshToken: SessionToken(rawValue: String(repeating: "r", count: 43)),
        refreshExpiresAt: Date(timeIntervalSince1970: 1_802_592_000), refreshGeneration: generation)
}

/// 构造指定资料版本的虚构用户 Protobuf 响应。
private func profileMessage(version: Int64 = 1) -> AzureFishProtocol.UserProfile {
    var message = AzureFishProtocol.UserProfile()
    message.userID = testUserID.uuidString.lowercased(); message.accountName = "fictional_user"
    message.nickname = "虚构测试"; message.profileVersion = version
    message.createdAtMs = 1_800_000_000_000; message.updatedAtMs = 1_800_000_000_000
    return message
}

/// 构造指定刷新代次且身份一致的虚构认证响应。
private func authMessage(generation: Int64 = 1) -> AuthResponse {
    var message = AuthResponse()
    message.environmentID = "test"; message.userID = testUserID.uuidString.lowercased()
    message.deviceID = testDeviceID.uuidString.lowercased(); message.sessionID = testSessionID.uuidString.lowercased()
    message.accessToken = String(repeating: "a", count: 43); message.refreshToken = String(repeating: "r", count: 43)
    message.accessExpiresAtMs = 1_800_000_900_000; message.refreshExpiresAtMs = 1_802_592_000_000
    message.refreshGeneration = generation; message.profile = profileMessage()
    return message
}

/// 编码指定错误码和状态的虚构 Protobuf 错误响应，附带重试间隔。
private func serviceResponse(_ code: String, status: Int) throws -> HTTPResponse {
    var message = ApiError()
    message.code = code; message.requestID = UUID().uuidString.lowercased(); message.field = "password"
    return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/protobuf", "Retry-After": "60"], body: try message.serializedData())
}

@Suite("账号 API 适配")
struct AccountAPITests {
    /// 验证删除恢复复用原请求字节，拒绝过期及跨环境材料。
    @Test func deletionRecoveryPreservesBytesAndRejectsExpiredOrForeignTickets() async throws {
        let proofToken = String(repeating: "p", count: 43)
        let transport = MockHTTPTransport { request, _ in
            if request.url.path == "/v1/auth/reauthenticate" {
                var response = ReauthenticateResponse(); response.token = proofToken; response.expiresAtMs = 1_800_000_300_000
                return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: try response.serializedData())
            }
            return HTTPResponse(statusCode: 202, headers: ["Content-Type": "application/protobuf"], body: Data())
        }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let current = try credentials(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let proof = try await api.execute(api.prepareReauthentication(operationID: UUID(), password: "Fictional-Password-123", action: .deleteAccount, using: current), using: current)
        let operation = try api.prepareSecurityAction(operationID: UUID(), action: .deleteAccount, proof: proof, using: current)
        let ticket = try api.deletionRecovery(for: operation, using: current, now: now)
        let encoded = try JSONEncoder().encode(ticket)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(current.refreshToken.rawValue))
        #expect(!String(reflecting: ticket).contains(proofToken))
        let restored = try JSONDecoder().decode(AccountDeletionRecovery.self, from: encoded)
        _ = try await api.execute(operation, using: current)
        try await api.recoverDeletion(restored, now: now.addingTimeInterval(60))
        let history = await transport.requests
        #expect(history[1].body == history[2].body && history[1].headers["Authorization"] == history[2].headers["Authorization"])
        let body = try AccountSecurityRequest(serializedBytes: #require(history[2].body))
        #expect(body.newPassword.isEmpty)
        await #expect(throws: APIClientError.invalidRequest) { try await api.recoverDeletion(restored, now: now.addingTimeInterval(601)) }
        let other = AccountAPI(environment: try environment("other"), transport: transport)
        await #expect(throws: APIClientError.operationEnvironmentMismatch) { try await other.recoverDeletion(restored, now: now) }
        #expect(await transport.requests.count == 3)
    }
    /// 验证注册请求只编码一次且认证响应映射为业务值。
    @Test func registrationSerializesOnceAndMapsDomainValues() async throws {
        let bytes = try authMessage().serializedData()
        let transport = MockHTTPTransport { _, attempt in
            if attempt == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 201, headers: ["Content-Type": "application/protobuf"], body: bytes)
        }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let id = UUID()
        let operation = try api.prepareRegistration(operationID: id, deviceID: testDeviceID,
            accountName: "fictional_user", password: "Fictional-Password-123", nickname: "虚构测试")
        let result = try await api.execute(operation)
        #expect(result.credentials.environmentID == "test" && result.profile.userID == testUserID)
        #expect(result.profile.nickname == "虚构测试")
        let history = await transport.requests
        #expect(history.count == 2)
        #expect(history[0].body == history[1].body)
        #expect(history[0].headers["X-Request-ID"] != history[1].headers["X-Request-ID"])
        #expect(history[0].url.path == "/v1/auth/register")
        #expect(history[0].headers["Authorization"] == nil)
        let decoded = try RegisterRequest(serializedBytes: #require(history[0].body))
        #expect(decoded.operationID == id.uuidString.lowercased())
        #expect(decoded.password == "Fictional-Password-123")
        #expect(!String(reflecting: operation).contains("Fictional-Password"))
        #expect(!String(reflecting: result).contains("虚构测试"))
        #expect(!String(reflecting: result.credentials).contains(result.credentials.accessToken.rawValue))
    }

    /// 验证资料修改保留字段 presence，并使用新 Bearer 重放原始正文。
    @Test func updatePresenceAndReplayWithNewBearer() async throws {
        let response = try profileMessage(version: 2).serializedData()
        let transport = MockHTTPTransport { _, _ in HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: response) }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let original = try credentials(), renewed = try credentials(generation: 2)
        let operation = try api.prepareProfileUpdate(operationID: UUID(), changes: .init(expectedVersion: 1, bio: ""), using: original)
        _ = try await api.execute(operation, using: original)
        _ = try await api.execute(operation, using: renewed)
        let history = await transport.requests
        #expect(history.count == 2 && history[0].body == history[1].body)
        #expect(history[0].headers["Authorization"] != history[1].headers["Authorization"])
        let message = try UpdateProfileRequest(serializedBytes: #require(history[0].body))
        #expect(message.hasBio && !message.hasNickname && message.bio.isEmpty)
        #expect(message.expectedProfileVersion == 1)
    }

    /// 验证请求拒绝跨账号、会话、环境及旧代次凭据。
    @Test func preventsCrossAccountSessionEnvironmentAndOldCredentialUse() async throws {
        let transport = MockHTTPTransport { _, _ in Issue.record("Unexpected network request"); return HTTPResponse(statusCode: 500) }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let current = try credentials(generation: 2)
        let operation = try api.prepareLogout(operationID: UUID(), using: current)
        await #expect(throws: APIClientError.missingCredentials) { try await api.execute(operation) }
        await #expect(throws: APIClientError.credentialsMismatch) { try await api.execute(operation, using: credentials(userID: UUID())) }
        await #expect(throws: APIClientError.credentialsMismatch) { try await api.execute(operation, using: credentials(sessionID: UUID())) }
        await #expect(throws: APIClientError.credentialsMismatch) { try await api.execute(operation, using: credentials()) }
        let other = AccountAPI(environment: try environment("other"), transport: transport)
        await #expect(throws: APIClientError.operationEnvironmentMismatch) { try await other.execute(operation, using: current) }
        #expect(await transport.requests.isEmpty)
    }

    /// 验证账号 API 不因业务 401 自行刷新或重试。
    @Test(arguments: ["INVALID_CREDENTIALS", "UNAUTHENTICATED", "REFRESH_REPLAY", "REAUTH_REQUIRED"])
    func doesNotAutomaticallyRefreshOrRetryBusiness401(code: String) async throws {
        let response = try serviceResponse(code, status: 401)
        let transport = MockHTTPTransport { _, _ in response }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let operation = try api.prepareLogin(operationID: UUID(), deviceID: testDeviceID, accountName: "fictional_user", password: "Wrong-Fictional-Password")
        do { _ = try await api.execute(operation); Issue.record("Expected business error") }
        catch APIClientError.service(let failure) {
            #expect(failure.statusCode == 401)
            #expect(failure.isUnauthenticated == (code == "UNAUTHENTICATED"))
            #expect(failure.field == "password" && failure.requestID != nil)
        }
        #expect(await transport.requests.count == 1)
    }

    /// 验证代理响应、MIME、截断、限流和未知错误码正确分类。
    @Test func classifiesProxyMIMETruncationRateLimitAndUnknownCode() async throws {
        let limited = try serviceResponse("RATE_LIMITED", status: 429)
        let unknown = try serviceResponse("NEW_ERROR", status: 409)
        let transport = MockHTTPTransport { _, count in
            switch count {
            case 1: return HTTPResponse(statusCode: 502, headers: ["Content-Type": "text/html"], body: Data("<html>proxy</html>".utf8))
            case 2: return HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/html"])
            case 3: return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: Data([255]))
            case 4: return limited
            default: return unknown
            }
        }
        let api = AccountAPI(environment: try environment(), transport: transport)
        await #expect(throws: APIClientError.unexpectedHTTPStatus(statusCode: 502, requestID: nil)) { try await api.health() }
        await #expect(throws: APIClientError.unexpectedContentType(statusCode: 200)) { try await api.health() }
        await #expect(throws: APIClientError.decodingFailed) { try await api.health() }
        do { _ = try await api.health(); Issue.record("Expected 429") }
        catch APIClientError.service(let failure) { #expect(failure.code == .rateLimited && failure.retryAfterSeconds == 60) }
        do { _ = try await api.health(); Issue.record("Expected unknown code") }
        catch APIClientError.service(let failure) { #expect(failure.code == .unknown && !failure.isUnauthenticated) }
        #expect(await transport.requests.count == 5)
    }

    /// 验证认证响应身份及刷新代次不匹配时被拒绝。
    @Test func rejectsAuthIdentityMismatchAndInvalidRefreshGeneration() async throws {
        var wrongEnvironment = authMessage(); wrongEnvironment.environmentID = "wrong"
        var wrongUser = authMessage(); wrongUser.profile.userID = UUID().uuidString
        var wrongDevice = authMessage(); wrongDevice.deviceID = UUID().uuidString
        var wrongExpiry = authMessage(generation: 2); wrongExpiry.refreshExpiresAtMs -= 1_000
        let replies = try [wrongEnvironment, wrongUser, wrongDevice, authMessage(), wrongExpiry].map { try $0.serializedData() }
        let transport = MockHTTPTransport { _, count in HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: replies[count - 1]) }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let login = try api.prepareLogin(operationID: UUID(), deviceID: testDeviceID, accountName: "fictional_user", password: "Fictional-Password-123")
        for _ in 0..<3 { await #expect(throws: APIClientError.invalidResponse) { try await api.execute(login) } }
        let refresh = try api.prepareRefresh(operationID: UUID(), using: credentials())
        await #expect(throws: APIClientError.invalidResponse) { try await api.execute(refresh) }
        await #expect(throws: APIClientError.invalidResponse) { try await api.execute(refresh) }
    }

    /// 验证有效刷新和无业务字段退出响应正确解码。
    @Test func validRefreshAndEmptyLogoutResponse() async throws {
        var renewedMessage = authMessage(generation: 2)
        renewedMessage.refreshExpiresAtMs += 86_400_000
        let auth = try renewedMessage.serializedData()
        let transport = MockHTTPTransport { _, count in
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: count == 1 ? auth : Data())
        }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let refresh = try api.prepareRefresh(operationID: UUID(), using: credentials())
        let renewed = try await api.execute(refresh)
        #expect(renewed.credentials.refreshGeneration == 2)
        let logout = try api.prepareLogout(operationID: UUID(), using: renewed.credentials)
        _ = try await api.execute(logout, using: renewed.credentials)
        let history = await transport.requests
        #expect(history[0].headers["Authorization"] == nil)
        #expect(history[1].headers["Authorization"] != nil)
    }

    /// 验证无效环境和超限请求在发送前被拒绝。
    @Test func validatesEnvironmentAndOversizedPayload() throws {
        for url in ["http://example.invalid", "https://u:p@example.invalid", "https://example.invalid/api", "https://example.invalid?token=x"] {
            #expect(throws: APIClientError.invalidEnvironment) { try APIEnvironment(identifier: "test", baseURL: URL(string: url)!) }
        }
        let api = AccountAPI(environment: try environment())
        #expect(throws: APIClientError.requestTooLarge) {
            try api.prepareRegistration(operationID: UUID(), deviceID: testDeviceID, accountName: "test", password: String(repeating: "x", count: 17_000), nickname: "test")
        }
        #expect(throws: APIClientError.invalidRequest) {
            try api.prepareProfileUpdate(operationID: UUID(), changes: .init(expectedVersion: 1), using: credentials())
        }
    }

    /// 验证取消向上传递且 API 不自行安装会话。
    @Test func cancellationPropagatesWithoutInstallingState() async throws {
        let transport = MockHTTPTransport { _, _ in throw CancellationError() }
        let api = AccountAPI(environment: try environment(), transport: transport)
        await #expect(throws: CancellationError.self) { try await api.profile(using: credentials()) }
        #expect(await transport.requests.count == 1)
    }
}

extension AccountAPITests {
    /// 验证退出补偿序列化保留访问令牌及原请求，不保留刷新令牌。
    @Test func logoutRevocationRoundTripKeepsOnlyAccessAndOriginalBody() async throws {
        let transport = MockHTTPTransport { _, _ in HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/protobuf"], body: Data()) }
        let api = AccountAPI(environment: try environment(), transport: transport)
        let creds = try credentials()
        let ticket = try api.prepareLogoutRevocation(operationID: UUID(), using: creds)
        let bytes = try JSONEncoder().encode(ticket)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(!text.contains(creds.refreshToken.rawValue))
        #expect(!String(reflecting: ticket).contains(creds.accessToken.rawValue))
        let restored = try JSONDecoder().decode(LogoutRevocation.self, from: bytes)
        try await api.executeLogoutRevocation(ticket, now: Date(timeIntervalSince1970: 1_800_000_000))
        try await api.executeLogoutRevocation(restored, now: Date(timeIntervalSince1970: 1_800_000_001))
        let requests = await transport.requests
        #expect(requests.count == 2 && requests[0].body == requests[1].body)
        #expect(requests.allSatisfy { $0.url.path == "/v1/auth/logout" })
        #expect(requests[0].headers["Authorization"] == "Bearer " + creds.accessToken.rawValue)
        await #expect(throws: APIClientError.invalidRequest) { try await api.executeLogoutRevocation(restored, now: creds.accessExpiresAt) }
        let other = AccountAPI(environment: try environment("other"), transport: transport)
        await #expect(throws: APIClientError.operationEnvironmentMismatch) { try await other.executeLogoutRevocation(restored) }
        #expect(await transport.requests.count == 2)
    }
}
