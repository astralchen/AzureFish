import Foundation
import AzureFishNetwork

/// 已序列化的一次账号操作；保留此值可用相同 operationID 和相同字节重试。
///
/// 注册／登录／刷新正文包含凭据，仅在短期内存持有，不写入日志或磁盘。
/// 账号代次、并发刷新合并及重启后的 pending operation 恢复由 App 的 SessionCoordinator 管理。
public struct AccountOperation<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let operationID: UUID?
    let environment: APIEnvironment
    let path: String
    let method: HTTPMethod
    let body: Data?
    let expectedStatus: Int
    let authorization: SessionIdentity?
    let decode: @Sendable (Data) throws -> Value
    public var description: String { "AccountOperation(\(method.rawValue) \(path), content redacted)" }
    public var debugDescription: String { description }
}

struct SessionIdentity: Sendable, Equatable {
    let environmentID: String
    let userID: UUID
    let deviceID: UUID
    let sessionID: UUID
    let minimumGeneration: Int64
    init(_ credentials: SessionCredentials) {
        environmentID = credentials.environmentID; userID = credentials.userID
        deviceID = credentials.deviceID; sessionID = credentials.sessionID
        minimumGeneration = credentials.refreshGeneration
    }
    func accepts(_ credentials: SessionCredentials) -> Bool {
        environmentID == credentials.environmentID && userID == credentials.userID && deviceID == credentials.deviceID
            && sessionID == credentials.sessionID && credentials.refreshGeneration >= minimumGeneration
    }
}
