import Foundation
import AzureFishNetwork

/// 账号接口准备阶段生成的不可变操作，包含一次序列化后的请求与响应转换规则。
///
/// 持有并重复执行同一值可保留 operationID 和请求字节；这不延长服务端的结果恢复窗口。
/// 注册、登录和刷新正文包含凭据，操作仅供短期内存持有，不写入日志或磁盘。
/// 应用层负责合并并发刷新、隔离账号代次，以及需要时恢复尚未完成的业务动作。
public struct AccountOperation<Value: Sendable>: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 写操作的业务 ID；读取资料和健康检查为 nil，表示没有写动作幂等标识。
    public let operationID: UUID?
    /// 准备操作时的完整环境；执行时必须与 AccountAPI 的环境值相等。
    let environment: APIEnvironment
    /// 相对服务根地址的接口路径，由 AccountAPI 固定，不包含凭据或用户输入。
    let path: String
    /// 执行该操作的 HTTP 方法。
    let method: HTTPMethod
    /// 准备阶段编码完成的正文；nil 表示无正文，执行与重试不重新编码。
    let body: Data?
    /// 允许按成功响应解码的唯一 HTTP 状态码；注册为 201，当前其他接口为 200。
    let expectedStatus: Int
    /// 受保护操作要求的会话作用域；nil 表示执行时不得额外提供 Bearer 凭据。
    let authorization: SessionIdentity?
    /// 在状态与 MIME 校验成功后将正文映射为业务值的闭包。
    ///
    /// 由 execute 在返回结果前调用，可抛出响应校验错误；不安装会话或触发 UI 回调。
    let decode: @Sendable (Data) throws -> Value
    /// 显示方法和固定接口路径的脱敏说明，不包含正文字节、凭据或用户标识。
    public var description: String { "AccountOperation(\(method.rawValue) \(path), content redacted)" }
    /// 与 `description` 相同的脱敏调试说明。
    public var debugDescription: String { description }
}

/// 受保护操作准备时绑定的身份与最低刷新代次，不保存令牌原文。
struct SessionIdentity: Sendable, Equatable {
    /// 准备操作时的服务环境标识。
    let environmentID: String
    /// 操作绑定的用户身份。
    let userID: UUID
    /// 操作绑定的客户端安装身份。
    let deviceID: UUID
    /// 操作绑定的会话身份。
    let sessionID: UUID
    /// 可接受的最低凭据代次；相同会话刷新后可以用更高代次凭据执行原操作。
    let minimumGeneration: Int64
    /// 从凭据提取身份与代次，不保存令牌或到期时间。
    init(_ credentials: SessionCredentials) {
        environmentID = credentials.environmentID; userID = credentials.userID
        deviceID = credentials.deviceID; sessionID = credentials.sessionID
        minimumGeneration = credentials.refreshGeneration
    }
    /// 检查环境、账号、设备、会话是否相同，以及凭据代次是否达到准备时的最低要求。
    ///
    /// 只判断操作作用域，不验证令牌是否到期或已被服务端撤销。
    func accepts(_ credentials: SessionCredentials) -> Bool {
        environmentID == credentials.environmentID && userID == credentials.userID && deviceID == credentials.deviceID
            && sessionID == credentials.sessionID && credentials.refreshGeneration >= minimumGeneration
    }
}
