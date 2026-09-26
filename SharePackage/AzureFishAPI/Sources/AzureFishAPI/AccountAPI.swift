import AzureFishProtocol
import Foundation
import AzureFishNetwork
import SwiftProtobuf

/// 将账号业务操作映射为 HTTP／Protobuf 请求，并校验响应后返回业务值。
///
/// prepare 方法只编码操作，execute 或直接读取方法才发起网络请求。实例持有固定环境
/// 和 HTTPClient，不维护全局登录态，不自动刷新令牌或写入 Keychain。并发请求不会在此串行化；
/// 同一会话的刷新合并、旧回包隔离和 UI 状态更新由应用层负责。
public struct AccountAPI: Sendable {
    /// 本实例使用的固定服务环境；已准备的操作只能由环境值完全一致的实例执行。
    public let environment: APIEnvironment
    private let client: HTTPClient

    /// 创建指定服务环境的账号调用器，尚不读取凭据或连接服务端。
    ///
    /// - Parameters:
    ///   - environment: 已校验的环境标识、根地址和安全策略。
    ///   - transport: 可注入的单次 HTTP 传输；nil 时由 HTTPClient 创建原生 URLSession 传输。
    public init(environment: APIEnvironment, transport: (any HTTPTransport)? = nil) {
        self.environment = environment
        client = HTTPClient(transport: transport, security: environment.security)
    }

    /// 将注册输入编码为可重复执行的操作，不在准备阶段创建账号。
    ///
    /// 字符串原样编码，账号规范化及密码、昵称校验由服务端完成。新的用户提交应使用新的
    /// operationID；网络重试保留返回的操作值，避免重新序列化。确认密码属于 UI 输入，不进入协议。
    ///
    /// - Parameters:
    ///   - operationID: 本次注册动作的全局唯一业务 ID。
    ///   - deviceID: 当前客户端安装的 UUID，服务端将其绑定到新会话。
    ///   - accountName: 待注册账号名；服务端去除首尾空白并转小写后校验唯一性。
    ///   - password: 原始密码，不 trim 或规范化，不得用于日志。
    ///   - nickname: 初始昵称，字符与空白规则由服务端校验。
    /// - Returns: 预期 HTTP 201 并映射为 AuthenticatedSession 的操作；尚未发送。
    /// - Throws: 正文编码失败时为 `.encodingFailed`，编码后超过 16 KiB 时为 `.requestTooLarge`。
    public func prepareRegistration(operationID: UUID, deviceID: UUID, accountName: String,
                                    password: String, nickname: String) throws -> AccountOperation<AuthenticatedSession> {
        var request = RegisterRequest()
        request.operationID = operationID.uuidString.lowercased(); request.deviceID = deviceID.uuidString.lowercased()
        request.accountName = accountName; request.password = password; request.nickname = nickname
        return try operation(request, id: operationID, path: "v1/auth/register", status: 201) { data in
            try Self.auth(data, environment: environment, expectedDevice: deviceID)
        }
    }

    /// 将密码登录输入编码为可重试操作，成功执行后返回新会话与用户资料。
    ///
    /// 准备阶段不检查密码是否正确，也不撤销已有会话；账号和密码原样交给服务端校验。
    ///
    /// - Parameters:
    ///   - operationID: 本次登录动作的全局唯一业务 ID，同一次动作重试时保留。
    ///   - deviceID: 本次会话绑定的客户端安装 UUID。
    ///   - accountName: 登录账号名，使用服务端规定的规范化规则。
    ///   - password: 原始密码，不在客户端 trim 或规范化。
    /// - Returns: 预期 HTTP 200 并映射为 AuthenticatedSession 的操作；不安装登录状态。
    /// - Throws: `.encodingFailed` 或 `.requestTooLarge`，准备失败时不会发送请求。
    public func prepareLogin(operationID: UUID, deviceID: UUID, accountName: String,
                             password: String) throws -> AccountOperation<AuthenticatedSession> {
        var request = LoginRequest()
        request.operationID = operationID.uuidString.lowercased(); request.deviceID = deviceID.uuidString.lowercased()
        request.accountName = accountName; request.password = password
        return try operation(request, id: operationID, path: "v1/auth/login") { data in
            try Self.auth(data, environment: environment, expectedDevice: deviceID)
        }
    }

    /// 用当前刷新令牌准备一次会话轮换操作，不在此处保存或替换凭据。
    ///
    /// 执行时不额外传入 Bearer。响应必须保持用户、设备、会话和绝对刷新截止一致，
    /// 且刷新代次恰好递增 1。同一会话的并发刷新应由调用方合并；需要重启恢复时，
    /// 由应用层按认证设计持久化动作 ID 和对应旧凭据，此方法不会访问 Keychain。
    ///
    /// - Parameters:
    ///   - operationID: 本次刷新动作的全局唯一 ID；响应丢失后复用原操作恢复结果。
    ///   - credentials: 与当前环境匹配的旧会话快照，正文中使用其 refreshToken。
    /// - Returns: 已编码的刷新操作；调用 execute 成功后获得下一代会话快照。
    /// - Throws: 环境不符时为 `.credentialsMismatch`，代次无法递增时为 `.invalidCredentials`，
    ///   或准备正文时的 `.encodingFailed`／`.requestTooLarge`。
    public func prepareRefresh(operationID: UUID, using credentials: SessionCredentials) throws -> AccountOperation<AuthenticatedSession> {
        try checkEnvironment(credentials)
        guard credentials.refreshGeneration < Int64.max else { throw APIClientError.invalidCredentials }
        var request = RefreshRequest()
        request.operationID = operationID.uuidString.lowercased(); request.refreshToken = credentials.refreshToken.rawValue
        return try operation(request, id: operationID, path: "v1/auth/refresh") { data in
            let result = try Self.auth(data, environment: environment, expectedDevice: credentials.deviceID)
            guard result.credentials.userID == credentials.userID, result.credentials.sessionID == credentials.sessionID,
                  result.credentials.refreshGeneration == credentials.refreshGeneration + 1,
                  result.credentials.refreshExpiresAt == credentials.refreshExpiresAt else { throw APIClientError.invalidResponse }
            return result
        }
    }

    /// 准备撤销当前会话的操作，绑定身份作用域但不固化访问令牌。
    ///
    /// 执行时需提供同一环境、账号、设备和会话且代次不低于准备时的凭据。相同操作可在
    /// 服务端恢复窗口内重试；返回确认值不自动清理本地凭据、页面或加密账号数据。
    ///
    /// - Parameters:
    ///   - operationID: 本次退出动作的全局唯一业务 ID。
    ///   - credentials: 用于确定目标会话和最低刷新代次的凭据。
    /// - Returns: 执行成功后产生 Acknowledgement 的受保护操作。
    /// - Throws: `.credentialsMismatch`，或正文准备失败对应的 `.encodingFailed`／`.requestTooLarge`。
    public func prepareLogout(operationID: UUID, using credentials: SessionCredentials) throws -> AccountOperation<Acknowledgement> {
        try checkEnvironment(credentials)
        var request = LogoutRequest(); request.operationID = operationID.uuidString.lowercased()
        return try operation(request, id: operationID, path: "v1/auth/logout", authorization: SessionIdentity(credentials)) { data in
            _ = try EmptyResponse(serializedBytes: data)
            return Acknowledgement()
        }
    }

    /// 准备基于指定资料版本的部分更新，并保留每个字段的 presence。
    ///
    /// 只在此处检查版本为正数且至少指定一个字段；昵称和简介的内容限制由服务端校验。
    /// 响应须属于当前用户且资料版本高于提交依据；本方法不自动处理服务端版本冲突。
    ///
    /// - Parameters:
    ///   - operationID: 本次编辑动作的全局唯一业务 ID，原请求重试不得重新分配。
    ///   - changes: 编辑依据及待更新字段；nil 保留原值，空 bio 明确表示清空。
    ///   - credentials: 绑定编辑操作的会话及最低刷新代次，执行时仍需提供可接受的凭据。
    /// - Returns: 成功执行后返回最新 UserProfile 的受保护操作，正文在准备时只编码一次。
    /// - Throws: `.credentialsMismatch`、`.invalidRequest`，或正文准备阶段的 `.encodingFailed`／`.requestTooLarge`。
    public func prepareProfileUpdate(operationID: UUID, changes: ProfileChanges,
                                     using credentials: SessionCredentials) throws -> AccountOperation<UserProfile> {
        try checkEnvironment(credentials)
        guard changes.expectedVersion > 0, changes.nickname != nil || changes.bio != nil else { throw APIClientError.invalidRequest }
        var request = UpdateProfileRequest()
        request.operationID = operationID.uuidString.lowercased(); request.expectedProfileVersion = changes.expectedVersion
        if let nickname = changes.nickname { request.nickname = nickname }
        if let bio = changes.bio { request.bio = bio }
        return try operation(request, id: operationID, path: "v1/me", method: .patch, authorization: SessionIdentity(credentials)) { data in
            let profile = try Self.profile(AzureFishProtocol.UserProfile(serializedBytes: data))
            guard profile.userID == credentials.userID, profile.version > changes.expectedVersion else { throw APIClientError.invalidResponse }
            return profile
        }
    }

    /// 发送 GET /v1/me 并返回校验后的当前用户资料。
    ///
    /// 不会读取或更新本地缓存。返回前检查资料用户与提供的凭据一致；访问令牌是否过期或
    /// 撤销仍由服务端判定，业务 401 不在本方法中触发刷新。
    ///
    /// - Parameter credentials: 与本实例环境一致的会话凭据，用于生成 Bearer 请求头。
    /// - Returns: 从响应映射的业务 UserProfile 值。
    /// - Throws: 凭据环境不符时为 `.credentialsMismatch`；其他校验、服务或传输失败遵循 execute 的错误语义，
    ///   取消以 `CancellationError` 传播。
    public func profile(using credentials: SessionCredentials) async throws -> UserProfile {
        try checkEnvironment(credentials)
        let operation = AccountOperation<UserProfile>(operationID: nil, environment: environment, path: "v1/me", method: .get,
            body: nil, expectedStatus: 200, authorization: SessionIdentity(credentials)) { data in
                let profile = try Self.profile(AzureFishProtocol.UserProfile(serializedBytes: data))
                guard profile.userID == credentials.userID else { throw APIClientError.invalidResponse }
                return profile
            }
        return try await execute(operation, using: credentials)
    }

    /// 发送无需认证的健康检查，确认服务状态与环境标识。
    ///
    /// - Returns: 状态为 ok 且环境与本实例匹配的 HealthStatus；不代表账号已认证。
    /// - Throws: 状态或环境不符合预期时为 `.invalidResponse`；其余错误与取消遵循 execute 的语义。
    public func health() async throws -> HealthStatus {
        let operation = AccountOperation<HealthStatus>(operationID: nil, environment: environment, path: "health", method: .get,
            body: nil, expectedStatus: 200, authorization: nil) { data in
                let response = try HealthResponse(serializedBytes: data)
                guard response.environmentID == environment.identifier, response.status == "ok" else { throw APIClientError.invalidResponse }
                return HealthStatus(status: response.status, environmentID: response.environmentID)
            }
        return try await execute(operation)
    }

    /// 执行已准备的操作，校验 HTTP／Protobuf 响应并返回对应业务值。
    ///
    /// 写操作按原 ID 和正文字节发送，读操作无正文；HTTPClient 在明确允许的暂时性传输
    /// 失败后至多自动重试一次。手动重复执行仍受服务端恢复窗口和幂等规则约束。
    ///
    /// 受保护操作可使用同一会话的较新凭据替换 Bearer，但不得更换用户、设备、环境或会话，
    /// 也不得退回更低代次。本方法不检查本机时间上的凭据过期，不自动刷新或安装会话。
    /// 状态及 MIME 校验成功后才调用操作的响应转换规则；错误状态与业务错误不会自动重试。
    ///
    /// - Parameters:
    ///   - operation: 由 prepare 方法返回的操作，准备环境必须与本实例完全一致。
    ///   - credentials: 受保护操作所需的当前凭据；注册、登录和刷新必须保持默认 nil。
    /// - Returns: 操作声明的业务结果，不附带本地缓存、Keychain 或 UI 更新。
    /// - Throws: 作用域或凭据不符合要求时抛出相应 APIClientError；业务失败为 `.service`，
    ///   传输失败为 `.network`，HTTP／解码／响应字段错误按对应分类报告。取消以 `CancellationError` 传播。
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
               let message = try? ApiError(serializedBytes: response.body), !message.code.isEmpty {
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

    /// 将协议消息编码一次并封装响应转换规则；编码结果超过 16 KiB 时拒绝创建操作。
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

    /// 校验协议资料的必要字段并映射业务值，不在此处验证资料是否属于当前操作的用户。
    private static func profile(_ message: AzureFishProtocol.UserProfile) throws -> UserProfile {
        guard let userID = UUID(uuidString: message.userID), !message.accountName.isEmpty, !message.nickname.isEmpty,
              message.profileVersion > 0, message.createdAtMs > 0, message.updatedAtMs > 0 else { throw APIClientError.invalidResponse }
        return UserProfile(userID: userID, accountName: message.accountName, nickname: message.nickname, bio: message.bio,
            version: message.profileVersion, createdAt: date(message.createdAtMs), updatedAt: date(message.updatedAtMs))
    }

    /// 校验认证响应的环境、设备、身份关系和凭据格式，映射成对会话值与资料。
    ///
    /// 刷新特有的用户／会话／代次关系由准备刷新时捕获的转换规则进一步校验。
    private static func auth(_ data: Data, environment: APIEnvironment, expectedDevice: UUID) throws -> AuthenticatedSession {
        let message = try AuthResponse(serializedBytes: data)
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
