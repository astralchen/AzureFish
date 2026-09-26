import Foundation
import AzureFishNetwork

/// 账号服务的稳定业务错误分类，原始值对应服务端协议码。
///
/// AccountAPI 将未识别的服务端 code 映射到 `.unknown`；直接使用 rawValue 初始化时，
/// RawRepresentable 仍按原有规则对不匹配的字符串返回 nil。
public enum APIErrorCode: String, Sendable {
    /// 请求字段未通过服务端校验，可结合错误的 field 定位输入。
    case validationFailed = "VALIDATION_FAILED"
    /// 请求正文不是可解码的 Protobuf 消息。
    case malformedProtobuf = "MALFORMED_PROTOBUF"
    /// 账号不存在或密码不匹配；服务端不区分这两种原因。
    case invalidCredentials = "INVALID_CREDENTIALS"
    /// 受保护请求的凭据缺失、无效、已撤销或已到期。
    case unauthenticated = "UNAUTHENTICATED"
    /// 已消费的 refresh token 被不同操作 ID 重放，对应会话已被撤销。
    case refreshReplay = "REFRESH_REPLAY"
    /// 规范化后的账号名已被其他账号占用。
    case accountTaken = "ACCOUNT_TAKEN"
    /// 提交的资料版本不是服务端当前版本；需读取最新资料并处理冲突。
    case profileVersionConflict = "PROFILE_VERSION_CONFLICT"
    /// 同一操作 ID 被用于不同请求字节、路由或会话作用域。
    case operationConflict = "OPERATION_CONFLICT"
    /// 注册或登录等认证动作的历史结果已不可恢复，需重新完成认证流程。
    case authAttemptExpired = "AUTH_ATTEMPT_EXPIRED"
    /// 刷新操作的结果已落后于会话当前代次，不应覆盖较新的凭据。
    case refreshSuperseded = "REFRESH_SUPERSEDED"
    /// 资料或退出动作的结果恢复窗口已过期；调用方需先对账当前状态。
    case operationResultExpired = "OPERATION_RESULT_EXPIRED"
    /// 请求的 Accept 头不接受服务端提供的 Protobuf 响应。
    case notAcceptable = "NOT_ACCEPTABLE"
    /// 请求正文的 Content-Type 不受服务端支持。
    case unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE"
    /// 服务端拒绝超出请求正文上限的数据。
    case payloadTooLarge = "PAYLOAD_TOO_LARGE"
    /// 请求触发服务端限流，可结合 Retry-After 决定后续等待。
    case rateLimited = "RATE_LIMITED"
    /// 服务端返回其他 HTTP 失败，例如路由不存在，不表示密码错误。
    case httpError = "HTTP_ERROR"
    /// 服务端发生内部错误，可保留请求 ID 用于诊断。
    case internalError = "INTERNAL_ERROR"
    /// 当前客户端无法识别的服务端业务码；原始未识别字符串不向上暴露。
    case unknown
}

/// 从 Protobuf 错误响应解析出的业务失败，不包含原始响应正文。
///
/// 仅在 HTTP 状态及业务码均满足条件时，isUnauthenticated 才为 true；是否刷新由应用层
/// 结合请求类型、已有凭据和刷新状态决定，本类型不发起刷新。
public struct APIServiceFailure: Sendable, Equatable {
    /// 错误响应的 HTTP 状态码，用于区分校验、认证、冲突和限流等失败。
    public let statusCode: Int
    /// 识别后的稳定业务码；服务端新增而当前客户端未知的值映射到 `.unknown`。
    public let code: APIErrorCode
    /// 错误关联的协议字段名；缺失或不在客户端允许字段集合中时为 `nil`。
    public let field: String?
    /// 可解析为 UUID 的请求标识，优先使用 X-Request-ID，其次使用错误体；均不可解析时为 `nil`。
    public let requestID: UUID?
    /// Retry-After 头中可解析的整数秒数，有效范围为 0～86400。
    ///
    /// 缺失、超范围或采用 HTTP 日期格式时为 `nil`；此值不会触发自动等待。
    public let retryAfterSeconds: Int?
    /// 是否同时满足 HTTP 401 和 `.unauthenticated`，可作为普通受保护请求评估刷新的信号。
    public var isUnauthenticated: Bool { statusCode == 401 && code == .unauthenticated }
}

/// 账号调用边界报告的失败，不携带密码、令牌、原始响应或底层错误 userInfo。
///
/// 任务取消继续以 `CancellationError` 传播，不包装为本枚举。
public enum APIClientError: Error, Sendable, Equatable {
    /// 环境标识、服务根地址、端口或传输安全策略不符合要求。
    case invalidEnvironment
    /// 操作准备时的环境与执行它的 AccountAPI 环境不完全相同。
    case operationEnvironmentMismatch
    /// 凭据环境、账号、设备、会话或代次不符合操作要求，或向无 Bearer 的操作额外提供了凭据。
    case credentialsMismatch
    /// 受保护操作执行时没有提供所需会话凭据。
    case missingCredentials
    /// 令牌格式、会话字段或时间关系无效，或刷新代次已无法继续递增。
    case invalidCredentials
    /// 资料更新缺少有效版本，或未指定任何待更新字段。
    case invalidRequest
    /// 客户端序列化的 Protobuf 正文超过 16 KiB，尚未发送至服务端。
    case requestTooLarge
    /// 准备操作时无法将协议消息编码为二进制正文。
    case encodingFailed
    /// 成功响应无法解码为操作预期的 Protobuf 消息。
    case decodingFailed
    /// 成功响应可解码，但身份、环境、版本或其他必要业务字段不符合操作约束。
    case invalidResponse
    /// 状态码符合预期，但响应 Content-Type 不是 application/protobuf。
    ///
    /// - Parameter statusCode: 收到的 HTTP 状态码，不附带原始响应正文。
    case unexpectedContentType(statusCode: Int)
    /// 响应状态不符合操作预期，且无法作为有效的 Protobuf 业务错误解释。
    ///
    /// - Parameters:
    ///   - statusCode: 收到的 HTTP 状态码，包括非预期的其他 2xx 状态。
    ///   - requestID: 从响应头解析的 UUID；缺失或格式不合法时为 nil。
    case unexpectedHTTPStatus(statusCode: Int, requestID: UUID?)
    /// 服务端返回可解析的业务错误；关联值包含状态、稳定码和已筛选的诊断字段。
    case service(APIServiceFailure)
    /// 发送阶段发生网络层失败；关联值保留脱敏后的传输错误分类。
    case network(NetworkError)
}
