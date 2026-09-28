import Foundation
import AzureFishProtocol

/// 再次认证与提交必须使用相同的动作。
public enum AccountSecurityAction: String, Sendable, CaseIterable {
    case changePassword = "change_password", logoutAll = "logout_all", deleteAccount = "delete_account"
}
/// 只允许短期内存持有的再次认证凭据。
public struct AccountReauthentication: Sendable, CustomStringConvertible {
    public let token: SessionToken
    public let expiresAt: Date
    public var description: String { "AccountReauthentication(<redacted>)" }
}
/// 当前账号的密码登录状态，以及删除前必须转让或解散的群。
public struct AccountSecurityInfo: Sendable {
    public let passwordConfigured: Bool
    public let ownedGroups: [ChatConversation]
}
/// 鉴权接口返回的头像资源；恢复默认后标识与 JPEG 同时为空。
public struct AccountAvatar: Sendable {
    public let id: String
    public let jpeg: Data
}

/// 删除申请的有限期恢复包，不包含密码或刷新令牌，只能保存到 ThisDeviceOnly Keychain。
public struct AccountDeletionRecovery: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UUID
    let operationID: UUID
    let environmentID: String
    let baseURL: URL
    let body: Data
    let accessToken: String
    public let expiresAt: Date
    public var description: String { "AccountDeletionRecovery(<redacted>)" }
    public var debugDescription: String { description }
}

extension AccountAPI {
    /// 在发送删除请求前保存同一请求字节；恢复包不会生成新的业务操作。
    public func deletionRecovery(for operation: AccountOperation<Bool>, using credentials: SessionCredentials,
        now: Date = Date()) throws -> AccountDeletionRecovery {
        try checkEnvironment(credentials)
        guard operation.environment == environment, operation.path == "v1/me/security/delete_account",
              operation.authorization?.accepts(credentials) == true, let id = operation.operationID,
              let body = operation.body else { throw APIClientError.invalidRequest }
        return AccountDeletionRecovery(userID: credentials.userID, operationID: id, environmentID: environment.identifier,
            baseURL: environment.baseURL, body: body, accessToken: credentials.accessToken.rawValue,
            expiresAt: min(now.addingTimeInterval(600), credentials.refreshExpiresAt))
    }
    /// 仅重试原删除申请；过期后不推断删除成功，也不清除业务数据。
    public func recoverDeletion(_ recovery: AccountDeletionRecovery, now: Date = Date()) async throws {
        guard recovery.environmentID == environment.identifier, recovery.baseURL == environment.baseURL else {
            throw APIClientError.operationEnvironmentMismatch
        }
        guard recovery.expiresAt > now, recovery.body.count <= 16 * 1024,
              let request = try? AccountSecurityRequest(serializedBytes: recovery.body), request.newPassword.isEmpty,
              request.operationID == recovery.operationID.uuidString.lowercased(), request.unknownFields.data.isEmpty else {
            throw APIClientError.invalidRequest
        }
        let token = try SessionToken(rawValue: recovery.accessToken)
        let operation = AccountOperation<Bool>(operationID: recovery.operationID, environment: environment,
            path: "v1/me/security/delete_account", method: .post, body: recovery.body, expectedStatus: 202,
            authorization: nil) { data in _ = try EmptyResponse(serializedBytes: data); return true }
        _ = try await executeValidated(operation, headers: ["Accept": "application/protobuf", "Content-Type": "application/protobuf",
            "Authorization": "Bearer " + token.rawValue])
    }
    /// 读取账号安全状态及删除前必须处理的群。
    public func security(using credentials: SessionCredentials) async throws -> AccountSecurityInfo {
        try checkEnvironment(credentials)
        let op = AccountOperation<AccountSecurityInfo>(operationID: nil, environment: environment,
            path: "v1/me/security", method: .get, body: nil, maximumResponseBytes: 8 * 1024 * 1024,
            expectedStatus: 200, authorization: SessionIdentity(credentials)) { data in
                let value = try AccountSecurityStatus(serializedBytes: data)
                return AccountSecurityInfo(passwordConfigured: value.passwordConfigured, ownedGroups: value.ownedGroups.map(ChatConversation.init))
            }
        return try await execute(op, using: credentials)
    }
    /// 准备限定当前会话和用途的密码再次认证，尚不发起网络请求。
    public func prepareReauthentication(operationID: UUID, password: String, action: AccountSecurityAction,
        using credentials: SessionCredentials) throws -> AccountOperation<AccountReauthentication> {
        try checkEnvironment(credentials)
        var input = ReauthenticateRequest(); input.operationID = operationID.uuidString.lowercased()
        input.password = password; input.action = action.rawValue
        return try operation(input, id: operationID, path: "v1/auth/reauthenticate", authorization: SessionIdentity(credentials)) { data in
            let value = try ReauthenticateResponse(serializedBytes: data)
            return AccountReauthentication(token: try SessionToken(rawValue: value.token), expiresAt: Date(timeIntervalSince1970: Double(value.expiresAtMs) / 1000))
        }
    }
    /// 准备敏感写操作；失败重试须复用返回值，不重新生成 ID 或请求正文。
    public func prepareSecurityAction(operationID: UUID, action: AccountSecurityAction, proof: AccountReauthentication,
        newPassword: String = "", using credentials: SessionCredentials) throws -> AccountOperation<Bool> {
        try checkEnvironment(credentials)
        var input = AccountSecurityRequest(); input.operationID = operationID.uuidString.lowercased()
        input.reauthToken = proof.token.rawValue; input.newPassword = newPassword
        return try operation(input, id: operationID, path: "v1/me/security/" + action.rawValue,
            status: action == .deleteAccount ? 202 : 200, authorization: SessionIdentity(credentials)) { data in
                _ = try EmptyResponse(serializedBytes: data); return true
            }
    }
    /// 空 JPEG 恢复默认头像；同一失败上传应复用返回的操作。
    public func prepareAvatar(operationID: UUID, expectedVersion: Int64, jpeg: Data,
        using credentials: SessionCredentials) throws -> AccountOperation<UserProfile> {
        try checkEnvironment(credentials)
        guard jpeg.count <= 256 * 1024 else { throw APIClientError.requestTooLarge }
        var input = UpdateAvatarRequest(); input.operationID = operationID.uuidString.lowercased()
        input.expectedProfileVersion = expectedVersion; input.jpeg = jpeg
        return AccountOperation(operationID: operationID, environment: environment, path: "v1/me/avatar", method: .post,
            body: try input.serializedData(), expectedStatus: 200, authorization: SessionIdentity(credentials)) { data in
                let value = try Self.profile(AzureFishProtocol.UserProfile(serializedBytes: data))
                guard value.userID == credentials.userID, value.version > expectedVersion else { throw APIClientError.invalidResponse }
                return value
            }
    }
    /// 读取本人或有权访问的用户头像，不经过系统磁盘 URLCache。
    public func avatar(user: UUID, using credentials: SessionCredentials) async throws -> AccountAvatar {
        try checkEnvironment(credentials)
        let op = AccountOperation<AccountAvatar>(operationID: nil, environment: environment,
            path: "v1/users/" + user.uuidString.lowercased() + "/avatar", method: .get, body: nil,
            maximumResponseBytes: 260 * 1024, expectedStatus: 200, authorization: SessionIdentity(credentials)) { data in
                let value = try AvatarResponse(serializedBytes: data)
                guard value.jpeg.count <= 256 * 1024, value.jpeg.isEmpty == value.avatarID.isEmpty else { throw APIClientError.invalidResponse }
                return AccountAvatar(id: value.avatarID, jpeg: value.jpeg)
            }
        return try await execute(op, using: credentials)
    }
}
