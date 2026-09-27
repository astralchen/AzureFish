import Foundation

/// 仅供退出补偿的有限期凭据，不含刷新令牌，不能恢复登录。
///
/// 编码数据包含访问令牌，只能存入独立的 ThisDeviceOnly Keychain 项，不得写入普通文件或日志。
public struct LogoutRevocation: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let operationID: UUID
    let environmentID: String
    let baseURL: URL
    let body: Data
    let accessToken: String
    public let expiresAt: Date
    public var description: String { "LogoutRevocation(<redacted>)" }
    public var debugDescription: String { description }
}
