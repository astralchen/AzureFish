import Foundation
import AzureFishAPI
import AzureFishMoments

/// 从窗口运行时投影动态流状态，管理当前页面的展开和操作状态。
@MainActor
final class MomentsViewModel {
    let runtime: MomentsRuntime
    let author: String
    private var observedEpoch: UUID
    private var observation: UUID?
    private var expanded: Set<String> = []
    private var busy: Set<String> = []
    private(set) var requestingPage = false
    var render: ((MomentsFeedState) -> Void)?
    var didFinishRefresh: (() -> Void)?

    init(runtime: MomentsRuntime, author: String = "") {
        self.runtime = runtime
        self.author = author
        observedEpoch = runtime.epoch
        observation = runtime.observe { [weak self] in self?.publishState() }
    }
    var state: MomentsFeedState {
        let posts = runtime.visible(author: author), owner = author.isEmpty ? runtime.userID : author
        let fallback = ChatUser(id: owner, nickname: owner == runtime.userID ? (runtime.session?.profile?.nickname ?? "AzureFish") : Localization.text("moments.album"), version: 0, avatarID: owner == runtime.userID ? runtime.session?.profile?.avatarID : nil, deleted: false)
        let album = runtime.albums[owner] ?? MomentsAlbum(owner: posts.first(where: { $0.author.id == owner })?.author ?? fallback)
        return MomentsFeedState(posts: posts, album: album, expanded: expanded, busy: busy,
            status: runtime.failure ?? (runtime.offline ? "moments.offline" : (!runtime.pending.isEmpty ? "moments.pendingActions" : nil)),
            loading: runtime.loading, footer: paginationState, canCompose: runtime.ready && !runtime.offline)
    }
    /// 投影运行时快照；账号生命周期改变时清除页面展开和忙碌状态。
    func publishState() {
        if observedEpoch != runtime.epoch {
            observedEpoch = runtime.epoch
            expanded = []
            busy = []
            requestingPage = false
        }
        render?(state)
    }
    func toggleExpanded(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        publishState()
    }
    /// 请求刷新或续页；自动续页传 retry 为 false，避免失败后滚动触发无限重试。
    func refresh(next: Bool = false, retry: Bool = true) {
        if next {
            guard !requestingPage, runtime.canLoadNextPage(author: author, retry: retry) else { return }
            requestingPage = true
        } else if !runtime.ready {
            didFinishRefresh?()
            return
        }
        runtime.launch { [weak self] in
            guard let self else { return }
            defer {
                if next { requestingPage = false }
                else { didFinishRefresh?() }
                publishState()
            }
            try await runtime.refresh(author: author, next: next)
        }
    }
    private var paginationState: MomentsPaginationState? {
        #if DEBUG
        if let preview = runtime.previewPagination { return preview }
        #endif
        guard !runtime.visible(author: author).isEmpty, !runtime.offline else { return nil }
        if runtime.loadingPageAuthor == author { return .loading }
        if runtime.pageFailure(author: author) != nil { return .failed }
        return runtime.hasMore(author: author) ? .idle : .ended
    }
    /// 按当前待处理快照重试写操作，再刷新列表；首个失败会中止本轮重试。
    func retry() {
        runtime.launch { [weak self] in
            guard let self else { return }
            for action in runtime.pending { try await runtime.mutate(action) }
            try await runtime.refresh(author: author)
        }
    }
    /// 同一动态只接受一个进行中的页面操作；若已有同类未知请求，优先重试其原始参数。
    func submit(_ action: MomentsPendingAction) {
        guard !runtime.offline, !busy.contains(action.post) else { return }
        busy.insert(action.post); publishState()
        runtime.launch { [weak self] in
            guard let self else { return }; defer { busy.remove(action.post); publishState() }
            let pending = runtime.pending.first { $0.post == action.post && $0.kind == action.kind }
            try await runtime.mutate(pending ?? action)
        }
    }

    isolated deinit { if let observation { runtime.remove(observation) } }
}
