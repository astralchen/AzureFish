import AzureFishProtocol
import Foundation
import AzureFishNetwork
import SwiftProtobuf

/// 首期账号接口适配器；一次构造正文，可注入传输，不持有全局登录态或自动刷新凭据。
public struct AccountAPI: Sendable {
    public let environment: APIEnvironment
    private let client: HTTPClient

    public init(environment: APIEnvironment, transport: (any HTTPTransport)? = nil) {
        self.environment = environment
        client = HTTPClient(transport: transport, security: environment.security)
    }

    /// 准备注册；客户端确认密码不进入网络请求，operationID 应与用户这次提交一起创建。
    public func prepareRegistration(operationID: UUID, deviceID: UUID, accountName: String,
                                    password: String, nickname: String) throws -> AccountOperation<AuthenticatedSession> {
        var request = Azurefish_V1_RegisterRequest()
        request.operationID = operationID.uuidString.lowercased(); request.deviceID = deviceID.uuidString.lowercased()
        request.accountName = accountName; request.password = password; request.nickname = nickname
        return try operation(request, id: operationID, path: "v1/auth/register", status: 201) { data in
            try Self.auth(data, environment: environment, expectedDevice: deviceID)
        }
    }

    public func prepareLogin(operationID: UUID, deviceID: UUID, accountName: String,
                             password: String) throws -> AccountOperation<AuthenticatedSession> {
        var request = Azurefish_V1_LoginRequest()
        request.operationID = operationID.uuidString.lowercased(); request.deviceID = deviceID.uuidString.lowercased()
        request.accountName = accountName; request.password = password
        return try operation(request, id: operationID, path: "v1/auth/login") { data in
            try Self.auth(data, environment: environment, expectedDevice: deviceID)
        }
    }

    /// 准备一次刷新；operationID 必须先连同旧凭据原子保存到 Keychain，重启恢复也复用该 ID。
    public func prepareRefresh(operationID: UUID, using credentials: SessionCredentials) throws -> AccountOperation<AuthenticatedSession> {
        try checkEnvironment(credentials)
        guard credentials.refreshGeneration < Int64.max else { throw APIClientError.invalidCredentials }
        var request = Azurefish_V1_RefreshRequest()
        request.operationID = operationID.uuidString.lowercased(); request.refreshToken = credentials.refreshToken.rawValue
        return try operation(request, id: operationID, path: "v1/auth/refresh") { data in
            let result = try Self.auth(data, environment: environment, expectedDevice: credentials.deviceID)
            guard result.credentials.userID == credentials.userID, result.credentials.sessionID == credentials.sessionID,
                  result.credentials.refreshGeneration == credentials.refreshGeneration + 1,
                  result.credentials.refreshExpiresAt == credentials.refreshExpiresAt else { throw APIClientError.invalidResponse }
            return result
        }
    }

    public func prepareLogout(operationID: UUID, using credentials: SessionCredentials) throws -> AccountOperation<Acknowledgement> {
        try checkEnvironment(credentials)
        var request = Azurefish_V1_LogoutRequest(); request.operationID = operationID.uuidString.lowercased()
        return try operation(request, id: operationID, path: "v1/auth/logout", authorization: SessionIdentity(credentials)) { data in
            _ = try Azurefish_V1_EmptyResponse(serializedBytes: data)
            return Acknowledgement()
        }
    }

    /// 准备版本化资料写入；提交后由调用方保留操作，不能为网络重试创建新 ID。
    public func prepareProfileUpdate(operationID: UUID, changes: ProfileChanges,
                                     using credentials: SessionCredentials) throws -> AccountOperation<UserProfile> {
        try checkEnvironment(credentials)
        guard changes.expectedVersion > 0, changes.nickname != nil || changes.bio != nil else { throw APIClientError.invalidRequest }
        var request = Azurefish_V1_UpdateProfileRequest()
        request.operationID = operationID.uuidString.lowercased(); request.expectedProfileVersion = changes.expectedVersion
        if let nickname = changes.nickname { request.nickname = nickname }
        if let bio = changes.bio { request.bio = bio }
        return try operation(request, id: operationID, path: "v1/me", method: .patch, authorization: SessionIdentity(credentials)) { data in
            let profile = try Self.profile(Azurefish_V1_UserProfile(serializedBytes: data))
            guard profile.userID == credentials.userID, profile.version > changes.expectedVersion else { throw APIClientError.invalidResponse }
            return profile
        }
    }

    public func profile(using credentials: SessionCredentials) async throws -> UserProfile {
        try checkEnvironment(credentials)
        let operation = AccountOperation<UserProfile>(operationID: nil, environment: environment, path: "v1/me", method: .get,
            body: nil, expectedStatus: 200, authorization: SessionIdentity(credentials)) { data in
                let profile = try Self.profile(Azurefish_V1_UserProfile(serializedBytes: data))
                guard profile.userID == credentials.userID else { throw APIClientError.invalidResponse }
                return profile
            }
        return try await execute(operation, using: credentials)
    }

    public func health() async throws -> HealthStatus {
        let operation = AccountOperation<HealthStatus>(operationID: nil, environment: environment, path: "health", method: .get,
            body: nil, expectedStatus: 200, authorization: nil) { data in
                let response = try Azurefish_V1_HealthResponse(serializedBytes: data)
                guard response.environmentID == environment.identifier, response.status == "ok" else { throw APIClientError.invalidResponse }
                return HealthStatus(status: response.status, environmentID: response.environmentID)
            }
        return try await execute(operation)
    }

    /// 执行已准备操作；受保护操作可传入同一 session 的较新凭据，正文保持不变。
    ///
    /// 不在 401 后隐式刷新，不修改 Keychain，不安装会话。取消直接抛出 CancellationError。
    public func execute<Value>(_ operation: AccountOperation<Value>, using credentials: SessionCredentials? = nil) async throws -> Value {
        try Task.checkCancellation()
        guard operation.environment == environment else { throw APIClientError.operationEnvironmentMismatch }
        var headers = ["Accept": "application/protobuf"]
        if operation.body != nil { headers["Content-Type"] = "application/protobuf" }
        if let identity = operation.authorization {
            guard let credentials else { throw APIClientError.missingCredentials }
            guard identity.accepts(credentials) else { throw APIClientError.credentialsMismatch }
            headers["Authorization"] = "Bearer " + credentials.accessToken.rawValue
        } else if credentials != nil {
            throw APIClientError.credentialsMismatch
        }
        let replay: HTTPReplayPolicy = operation.operationID.map { .idempotentWriteOnce(operationID: $0) } ?? .readOnce
        let request = HTTPRequest(url: environment.url(path: operation.path), method: operation.method, headers: headers,
                                  body: operation.body, maximumResponseBytes: 64 * 1024, replayPolicy: replay)
        let response: HTTPResponse
        do { response = try await client.send(request) }
        catch let error as NetworkError { throw APIClientError.network(error) }
        try Task.checkCancellation()
        let mime = response.header("Content-Type")?.split(separator: ";", omittingEmptySubsequences: false).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let requestID = response.header("X-Request-ID").flatMap(UUID.init(uuidString:))
        guard response.statusCode == operation.expectedStatus else {
            if !(200...299).contains(response.statusCode), mime == "application/protobuf",
               let message = try? Azurefish_V1_ApiError(serializedBytes: response.body), !message.code.isEmpty {
                let allowedFields = ["operation_id", "device_id", "account_name", "password", "nickname", "bio", "profile", "expected_profile_version"]
                let retry = response.header("Retry-After").flatMap(Int.init).flatMap { (0...86400).contains($0) ? $0 : nil }
                throw APIClientError.service(APIServiceFailure(statusCode: response.statusCode,
                    code: APIErrorCode(rawValue: message.code) ?? .unknown, field: allowedFields.contains(message.field) ? message.field : nil,
                    requestID: requestID ?? UUID(uuidString: message.requestID), retryAfterSeconds: retry))
            }
            throw APIClientError.unexpectedHTTPStatus(statusCode: response.statusCode, requestID: requestID)
        }
        guard mime == "application/protobuf" else { throw APIClientError.unexpectedContentType(statusCode: response.statusCode) }
        do {
            let value = try operation.decode(response.body)
            try Task.checkCancellation()
            return value
        } catch let error as APIClientError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw APIClientError.decodingFailed }
    }

    private func operation<M: Message, Value: Sendable>(_ message: M, id: UUID, path: String, method: HTTPMethod = .post,
        status: Int = 200, authorization: SessionIdentity? = nil, decode: @escaping @Sendable (Data) throws -> Value) throws -> AccountOperation<Value> {
        let bytes: Data
        do { bytes = try message.serializedData() } catch { throw APIClientError.encodingFailed }
        guard bytes.count <= 16 * 1024 else { throw APIClientError.requestTooLarge }
        return AccountOperation(operationID: id, environment: environment, path: path, method: method, body: bytes,
                                expectedStatus: status, authorization: authorization, decode: decode)
    }

    private func checkEnvironment(_ credentials: SessionCredentials) throws {
        guard credentials.environmentID == environment.identifier else { throw APIClientError.credentialsMismatch }
    }

    private static func profile(_ message: Azurefish_V1_UserProfile) throws -> UserProfile {
        guard let userID = UUID(uuidString: message.userID), !message.accountName.isEmpty, !message.nickname.isEmpty,
              message.profileVersion > 0, message.createdAtMs > 0, message.updatedAtMs > 0 else { throw APIClientError.invalidResponse }
        return UserProfile(userID: userID, accountName: message.accountName, nickname: message.nickname, bio: message.bio,
            version: message.profileVersion, createdAt: date(message.createdAtMs), updatedAt: date(message.updatedAtMs))
    }

    private static func auth(_ data: Data, environment: APIEnvironment, expectedDevice: UUID) throws -> AuthenticatedSession {
        let message = try Azurefish_V1_AuthResponse(serializedBytes: data)
        guard message.environmentID == environment.identifier, let userID = UUID(uuidString: message.userID),
              let deviceID = UUID(uuidString: message.deviceID), deviceID == expectedDevice,
              let sessionID = UUID(uuidString: message.sessionID), message.hasProfile else { throw APIClientError.invalidResponse }
        let profile = try profile(message.profile)
        guard profile.userID == userID else { throw APIClientError.invalidResponse }
        let credentials = try SessionCredentials(environmentID: message.environmentID, userID: userID, deviceID: deviceID, sessionID: sessionID,
            accessToken: SessionToken(rawValue: message.accessToken), accessExpiresAt: date(message.accessExpiresAtMs),
            refreshToken: SessionToken(rawValue: message.refreshToken), refreshExpiresAt: date(message.refreshExpiresAtMs), refreshGeneration: message.refreshGeneration)
        return AuthenticatedSession(credentials: credentials, profile: profile)
    }

    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
}
