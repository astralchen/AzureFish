import AzureFishAPI
import Foundation

/// 管理分页、当前素材和权威互动状态；播放器与 UIKit 导航由控制器持有。
@MainActor
final class ShortVideoViewModel {
    private let runtime: ShortVideoRuntime
    private(set) var items: [ShortVideoItem] = []
    var index = 0
    private(set) var more = true
    private(set) var fetching = false
    private(set) var mutating = false
    var errorKey: String?
    var current: ShortVideoItem? { items.indices.contains(index) ? items[index] : nil }
    var changed: (() -> Void)?
    var pageLoaded: (() -> Void)?
    var hasPendingLike: Bool { pendingLike != nil }
    private var cursor = ""
    private var refreshVersion = UUID()
    private var pendingLike: (id: String, value: Bool, operation: UUID)?
    private var feedTask: Task<Void, Never>?, actionTask: Task<Void, Never>?
    private var stopObserver: UUID?

    init(runtime: ShortVideoRuntime) {
        self.runtime = runtime
        stopObserver = runtime.observeStop { [weak self] in
            guard let self else { return }
            feedTask?.cancel(); actionTask?.cancel()
            items = []; index = 0; cursor = ""; pendingLike = nil
            fetching = false; mutating = false; more = false
            changed?()
        }
    }

    func cancelRequests() { feedTask?.cancel(); actionTask?.cancel() }

    /// 请求下一页；失败保留已展示素材与游标，重复触发合并为一次请求。
    func loadNextPage() {
        guard !fetching, more else { return }
        guard let api = runtime.api else { errorKey = "shortVideo.failed"; changed?(); return }
        fetching = true; errorKey = nil; changed?()
        feedTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await runtime.work { [cursor] in try await api.list(cursor: cursor) }
                try Task.checkCancellation()
                let known = Set(items.map(\.id))
                items.append(contentsOf: page.videos.filter { !known.contains($0.id) })
                cursor = page.cursor; more = page.hasMore
                pageLoaded?()
            } catch is CancellationError {} catch { errorKey = shortVideoErrorKey(error) }
            fetching = false; changed?()
        }
    }

    /// 刷新当前素材；取消旧读取，避免读取覆盖正在提交的点赞状态。
    func refreshCurrent() {
        guard let item = current, let api = runtime.api, !mutating else { return }
        actionTask?.cancel(); refreshVersion = UUID()
        let version = refreshVersion
        actionTask = Task { [weak self] in
            guard let self else { return }
            if let value = try? await runtime.work({ try await api.get(item.id) }), !Task.isCancelled,
               refreshVersion == version { update(value) }
        }
    }

    func update(_ item: ShortVideoItem) {
        // 评论等其他入口的写响应优先于此前发出的详情快照。
        refreshVersion = UUID()
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        changed?()
    }

    /// 设置点赞目标状态；失败后的手动重试沿用原目标和 operation ID。
    func setLike() {
        guard let item = current, let api = runtime.api, !mutating else { return }
        if pendingLike?.id != item.id { pendingLike = (item.id, !item.liked, UUID()) }
        guard let pending = pendingLike else { return }
        actionTask?.cancel(); mutating = true; changed?()
        actionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await runtime.work { try await api.like(pending.id, liked: pending.value, operation: pending.operation) }
                update(value); pendingLike = nil; errorKey = nil
            } catch is CancellationError {} catch { errorKey = shortVideoErrorKey(error) }
            mutating = false; changed?()
        }
    }

    isolated deinit {
        feedTask?.cancel(); actionTask?.cancel()
        if let stopObserver { runtime.remove(stopObserver) }
    }
}
