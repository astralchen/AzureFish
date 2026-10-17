import AzureFishChat

/// 会话列表的内容状态；空数组只有在完整快照已落库后才表示没有聊天。
enum ChatListContentState: Equatable {
    case content, loading, empty, noResults, failed, storageFailure

    static func resolve(hasSnapshot: Bool, synchronization: ChatSynchronizationState,
                        storageFailure: Bool, totalCount: Int, matchCount: Int,
                        searching: Bool) -> Self {
        if storageFailure { return .storageFailure }
        if matchCount > 0 { return .content }
        if !hasSnapshot && totalCount == 0 {
            return synchronization == .failed ? .failed : .loading
        }
        return searching ? .noResults : .empty
    }

    var titleKey: String {
        switch self {
        case .content: return ""
        case .loading: return "chat.list.loading"
        case .empty: return "chat.list.empty"
        case .noResults: return "chat.list.noResults"
        case .failed: return "chat.list.failed"
        case .storageFailure: return "chat.live.storageFailure"
        }
    }
    var detailKey: String? {
        switch self {
        case .empty: return "chat.list.emptyHelp"
        case .noResults: return "chat.list.searchHelp"
        case .failed: return "chat.list.retryHelp"
        default: return nil
        }
    }
}
