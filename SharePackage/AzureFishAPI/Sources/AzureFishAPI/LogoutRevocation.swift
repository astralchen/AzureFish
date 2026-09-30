import Foundation

/// 仅供退出补偿的有限期凭据，不含刷新令牌，不能恢复登录。
///
/// 编码数据包含访问令牌，只能存入独立的 ThisDeviceOnly Keychain 项，不得写入普通文件或日志。
public struct LogoutRevocation: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    public let operationID: UUID
    /// 原退出操作所属的服务环境标识。
    let environmentID: String
    /// 原退出操作所属的服务根地址。
    let baseURL: URL
    /// 退出请求的原始 Protobuf 字节，补偿时不重新编码；与凭据一并受保护保存。
    let body: Data
    /// 仅供退出补偿的访问令牌原文，不含刷新令牌，不得记录到日志。
    let accessToken: String
    /// 本机允许使用退出补偿材料的截止时间。
    public let expiresAt: Date
    /// 隐藏退出补偿内容及凭据的固定描述。
    public var description: String { "LogoutRevocation(<redacted>)" }
    /// 与 description 相同的脱敏调试描述。
    public var debugDescription: String { description }
}
