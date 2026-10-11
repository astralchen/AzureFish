import AzureFishAPI
import AzureFishMoments

/// 识别应撤回本地内容的明确服务端错误；普通网络失败不视为失权。
func isMomentUnavailable(_ error: any Error) -> Bool {
    if case APIClientError.service(let failure) = error { return failure.code == .momentUnavailable || failure.code.rawValue == "MEDIA_NOT_FOUND" }
    return false
}
/// 将业务及媒体处理错误映射为页面本地化键，未识别错误使用通用失败文案。
func momentsErrorKey(_ error: any Error) -> String {
    if case MomentsMediaError.processingFailed(let code) = error, ["INVALID_MEDIA", "MEDIA_TYPE_MISMATCH"].contains(code) { return "moments.mediaInvalid" }
    if error as? APIClientError == .invalidRequest { return "moments.invalid" }
    if case APIClientError.service(let failure) = error {
        switch failure.code.rawValue {
        case "MOMENT_UNAVAILABLE": return "moments.unavailable"
        case "MOMENT_VERSION_CONFLICT": return "moments.conflict"
        case "VALIDATION_FAILED", "MOMENT_ID_CONFLICT": return "moments.invalid"
        case "MOMENT_INTERACTION_LIMIT": return "moments.limit"
        default: break
        }
    }
    return "moments.failed"
}
