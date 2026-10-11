import Foundation

/// 续页状态独立于顶部刷新；结束标记只用于服务端确认没有下一页的列表。
enum MomentsPaginationState: String {
    case idle, loading, failed, ended
    @MainActor var label: String {
        let key = switch self {
        case .idle: "moments.more"
        case .loading: "moments.loading"
        case .failed: "moments.pageRetry"
        case .ended: "moments.pageEnd"
        }
        return Localization.text(key)
    }
    var allowsRetry: Bool { self == .idle || self == .failed }
}
