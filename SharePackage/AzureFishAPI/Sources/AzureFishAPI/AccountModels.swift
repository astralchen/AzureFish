import Foundation

/// 不透明会话令牌的内存值，提供显式访问原文和脱敏描述。
///
/// 仅检查长度与字符范围，不解码、不判断服务端有效性，也不自动保存至 Keychain。
/// 描述脱敏不代表原文无法通过属性、反射或进程内存读取。
public struct SessionToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 令牌原始字符串；只在构造认证请求或保存凭据时显式读取，避免记录到日志。
    public let rawValue: String
    /// 校验字符格式并保存令牌原文。
    ///
    /// - Parameter rawValue: 恰好 43 个 ASCII 字母、数字、短横线或下划线组成的字符串，不进行 trim。
    /// - Throws: 长度或字符不符合要求时抛出 `APIClientError.invalidCredentials`。
    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 43, rawValue.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw APIClientError.invalidCredentials }
        self.rawValue = rawValue
    }
    /// 隐藏令牌原文的固定说明。
    public var description: String { "SessionToken(<redacted>)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 一个会话的身份、成对凭据和有效期快照。
///
/// 初始化只校验字段之间的基本约束，不确认凭据来源、当前是否过期或服务端是否撤销。
/// 持久化、账号切换及刷新结果安装由应用层管理；此值本身不访问 Keychain 或磁盘。
public struct SessionCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 会话所属的非空环境标识；准备和执行操作时须与对应 API 环境匹配。
    public let environmentID: String
    /// 会话所属用户的稳定身份，用于隔离账号数据。
    public let userID: UUID
    /// 创建会话时绑定的安装 UUID，不表示硬件认证结果。
    public let deviceID: UUID
    /// 当前会话身份；同一会话刷新时保持不变，重新登录通常产生新值。
    public let sessionID: UUID
    /// 当前代次的访问凭据，受保护操作将其原文放入 Bearer 请求头。
    public let accessToken: SessionToken
    /// 访问凭据到期时间，必须晚于 Unix epoch 且不晚于 refreshExpiresAt。
    ///
    /// 初始化不与当前时钟比较，因此可用于表示尚待服务端验证的已过期凭据。
    public let accessExpiresAt: Date
    /// 当前代次的刷新凭据；刷新请求将其写入 Protobuf 正文。
    public let refreshToken: SessionToken
    /// 会话刷新凭据的绝对截止时间，须为有限日期且不早于 accessExpiresAt。
    public let refreshExpiresAt: Date
    /// 服务端确认的正数刷新代次，用于防止旧凭据覆盖较新结果。
    public let refreshGeneration: Int64

    /// 从调用方提供的身份和成对令牌构造会话快照。
    ///
    /// - Parameters:
    ///   - environmentID: 非空服务环境标识；本初始化不复用 APIEnvironment 的字符集校验。
    ///   - userID: 服务端用户身份。
    ///   - deviceID: 会话绑定的客户端安装身份。
    ///   - sessionID: 服务端会话身份。
    ///   - accessToken: 访问令牌的已校验格式值。
    ///   - accessExpiresAt: 访问到期时间，须有限、晚于 Unix epoch 且不晚于刷新截止。
    ///   - refreshToken: 与访问令牌同一代次的刷新令牌。
    ///   - refreshExpiresAt: 有限的会话刷新绝对截止时间。
    ///   - refreshGeneration: 大于 0 的刷新代次。
    /// - Throws: 环境、代次或日期关系无效时抛出 `APIClientError.invalidCredentials`。
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
    /// 隐藏身份标识和令牌内容的固定说明。
    public var description: String { "SessionCredentials(<redacted>)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 从账号接口映射的用户资料值，供业务层转换为持久数据或界面状态。
///
/// 该类型与 AzureFishProtocol.UserProfile 独立；创建资料值不会更新缓存、数据库或页面。
public struct UserProfile: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 资料所属用户的稳定身份。
    public let userID: UUID
    /// 服务端规范化后的账号名，当前资料接口不允许修改。
    public let accountName: String
    /// 服务端返回的昵称，保留原始文本，不在业务值中进行本地化或 trim。
    public let nickname: String
    /// 用户简介；空字符串表示未设置或已清空。
    public let bio: String
    /// 服务端资料版本，映射时要求为正数；编辑提交应携带读取时的版本。
    public let version: Int64
    /// 由服务端 Unix 毫秒时间戳转换的账号创建时间。
    public let createdAt: Date
    /// 由服务端 Unix 毫秒时间戳转换的资料更新时间，不用于替代版本冲突检查。
    public let updatedAt: Date
    /// 仅显示资料版本的脱敏说明，不包含用户标识、昵称或简介。
    public var description: String { "UserProfile(version: \(version), content redacted)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 一次成功认证或刷新返回的会话快照及同账号资料。
///
/// AccountAPI 在返回前检查响应身份关系；应用层仍需按账号代次协调结果安装，
/// 并以自己的持久化流程保存成对凭据，不能把返回此值当作登录状态已安装。
public struct AuthenticatedSession: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 此次响应中的会话身份与成对令牌。
    public let credentials: SessionCredentials
    /// 与 credentials.userID 对应的权威资料快照。
    public let profile: UserProfile
    /// 隐藏凭据和资料内容的固定说明。
    public var description: String { "AuthenticatedSession(<redacted>)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 一次资料编辑的版本依据和待更新字段。
///
/// 字段的 nil 表示保留服务端原值，显式空简介表示清空；本类型不自动合并版本冲突。
public struct ProfileChanges: Sendable {
    /// 编辑基于的资料版本；准备请求时要求为正数，服务端再检查是否等于当前版本。
    public let expectedVersion: Int64
    /// 拟更新的昵称，默认 nil 表示不修改；空或全空白文本会被服务端拒绝。
    public let nickname: String?
    /// 拟更新的简介，默认 nil 表示不修改；空字符串表示显式清空。
    public let bio: String?
    /// 保存资料修改意图，暂不执行校验、编码或网络发送。
    ///
    /// - Parameters:
    ///   - expectedVersion: 编辑所依据的服务端资料版本。
    ///   - nickname: 待提交昵称，默认 nil；字符限制由服务端校验。
    ///   - bio: 待提交简介，默认 nil；空字符串与 nil 的语义不同。
    public init(expectedVersion: Int64, nickname: String? = nil, bio: String? = nil) {
        self.expectedVersion = expectedVersion; self.nickname = nickname; self.bio = bio
    }
}

/// 健康检查成功返回的服务状态和环境信息。
///
/// AccountAPI 只在状态为 ok 且环境与请求一致时返回此值；它不代表账号已经认证。
public struct HealthStatus: Sendable, Equatable {
    /// 已验证的健康状态字符串，当前为 "ok"。
    public let status: String
    /// 服务端返回且与请求环境匹配的环境标识。
    public let environmentID: String
}

/// 已收到并成功解码的无业务字段响应。
///
/// 当前由退出操作返回；它不自动清理应用中的凭据、内存状态或账号数据。
public struct Acknowledgement: Sendable, Equatable {}
