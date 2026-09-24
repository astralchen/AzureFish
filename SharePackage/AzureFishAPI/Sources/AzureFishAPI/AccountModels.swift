import Foundation

/// 不透明会话令牌；显式读取 rawValue 才能交给 Keychain 或 HTTP 边界。
/// 描述始终脱敏，但不承诺通过反射或进程内存检查隐藏数据。
public struct SessionToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 43, rawValue.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw APIClientError.invalidCredentials }
        self.rawValue = rawValue
    }
    public var description: String { "SessionToken(<redacted>)" }
    public var debugDescription: String { description }
}

/// 服务端确认的会话值；本类型不保存到磁盘、不判断本机时钟是否可信。
public struct SessionCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let environmentID: String
    public let userID: UUID
    public let deviceID: UUID
    public let sessionID: UUID
    public let accessToken: SessionToken
    public let accessExpiresAt: Date
    public let refreshToken: SessionToken
    public let refreshExpiresAt: Date
    public let refreshGeneration: Int64

    /// 从已验证的响应或 Keychain 认证包恢复；过期与撤销仍由服务端判定。
    public init(environmentID: String, userID: UUID, deviceID: UUID, sessionID: UUID,
                accessToken: SessionToken, accessExpiresAt: Date, refreshToken: SessionToken,
                refreshExpiresAt: Date, refreshGeneration: Int64) throws {
        guard !environmentID.isEmpty, refreshGeneration > 0,
              accessExpiresAt.timeIntervalSince1970.isFinite, refreshExpiresAt.timeIntervalSince1970.isFinite,
              accessExpiresAt.timeIntervalSince1970 > 0, accessExpiresAt <= refreshExpiresAt else { throw APIClientError.invalidCredentials }
        self.environmentID = environmentID; self.userID = userID; self.deviceID = deviceID; self.sessionID = sessionID
        self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken; self.refreshExpiresAt = refreshExpiresAt; self.refreshGeneration = refreshGeneration
    }
    public var description: String { "SessionCredentials(<redacted>)" }
    public var debugDescription: String { description }
}

/// 当前账号资料，供 Repository 转换为界面状态；不暴露 Protobuf 类型。
public struct UserProfile: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UUID
    public let accountName: String
    public let nickname: String
    public let bio: String
    public let version: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public var description: String { "UserProfile(version: \(version), content redacted)" }
    public var debugDescription: String { description }
}

/// 登录或刷新确认的会话与同账号资料；App 应原子更新凭据，并校验账号代次。
public struct AuthenticatedSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentials: SessionCredentials
    public let profile: UserProfile
    public var description: String { "AuthenticatedSession(<redacted>)" }
    public var debugDescription: String { description }
}

/// 资料补丁；nil 表示不修改，空 bio 表示显式清空。
public struct ProfileChanges: Sendable {
    public let expectedVersion: Int64
    public let nickname: String?
    public let bio: String?
    public init(expectedVersion: Int64, nickname: String? = nil, bio: String? = nil) {
        self.expectedVersion = expectedVersion; self.nickname = nickname; self.bio = bio
    }
}

public struct HealthStatus: Sendable, Equatable {
    public let status: String
    public let environmentID: String
}

/// 已由服务端确认的空结果。
public struct Acknowledgement: Sendable, Equatable {}
