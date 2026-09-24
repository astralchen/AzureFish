import Foundation
import AzureFishNetwork

/// 稳定业务码；新增且尚未识别的服务端 code 映射到 unknown，保留 HTTP 状态供兜底。
public enum APIErrorCode: String, Sendable {
    case validationFailed = "VALIDATION_FAILED", malformedProtobuf = "MALFORMED_PROTOBUF"
    case invalidCredentials = "INVALID_CREDENTIALS", unauthenticated = "UNAUTHENTICATED", refreshReplay = "REFRESH_REPLAY"
    case accountTaken = "ACCOUNT_TAKEN", profileVersionConflict = "PROFILE_VERSION_CONFLICT", operationConflict = "OPERATION_CONFLICT"
    case authAttemptExpired = "AUTH_ATTEMPT_EXPIRED", refreshSuperseded = "REFRESH_SUPERSEDED", operationResultExpired = "OPERATION_RESULT_EXPIRED"
    case notAcceptable = "NOT_ACCEPTABLE", unsupportedMediaType = "UNSUPPORTED_MEDIA_TYPE", payloadTooLarge = "PAYLOAD_TOO_LARGE"
    case rateLimited = "RATE_LIMITED", httpError = "HTTP_ERROR", internalError = "INTERNAL_ERROR", unknown
}

/// 已解析且不包含正文的服务端错误；仅 isUnauthenticated 可作为普通受保护请求尝试刷新的信号。
public struct APIServiceFailure: Sendable, Equatable {
    public let statusCode: Int
    public let code: APIErrorCode
    public let field: String?
    public let requestID: UUID?
    public let retryAfterSeconds: Int?
    public var isUnauthenticated: Bool { statusCode == 401 && code == .unauthenticated }
}

/// 客户端边界错误；不包含密码、令牌、原始响应或底层错误 userInfo。
public enum APIClientError: Error, Sendable, Equatable {
    case invalidEnvironment
    case operationEnvironmentMismatch
    case credentialsMismatch
    case missingCredentials
    case invalidCredentials
    case invalidRequest
    case requestTooLarge
    case encodingFailed
    case decodingFailed
    case invalidResponse
    case unexpectedContentType(statusCode: Int)
    case unexpectedHTTPStatus(statusCode: Int, requestID: UUID?)
    case service(APIServiceFailure)
    case network(NetworkError)
}
