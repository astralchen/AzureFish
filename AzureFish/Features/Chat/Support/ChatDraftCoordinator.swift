import Foundation

/// 主 Actor 收集快照；存储在提交瞬间排队，因此离开后立即重进也能读到最后一次提交。
@MainActor
@available(iOS 16.0, *)
final class ChatDraftCoordinator {
    /// 尚待展示保存失败提示的会话集合，使页面退出后的失败可在下次进入时提示。
    static var pendingFailures: Set<String> = []
    /// 此协调器负责的会话标识，应与传入快照的会话标识一致。
    let conversationID: String
    /// 按提交顺序处理读取、保存及删除的可注入存储。
    let store: any ChatDraftStoring
    /// 当前等待 300 毫秒防抖窗口结束的任务；新内容到达时取消。
    private var pending: Task<Void, Never>?
    /// 最近一次收到的页面快照；尚未恢复或收到变更时为 `nil`。
    private var latest: ChatDraftSnapshot?
    /// 最近提交或恢复的内容基线，用于去重；当前提交失败后置为 `nil` 以允许重试。
    private var submitted: ChatDraftSnapshot?
    /// 内容变更的本地代次，用于阻止旧防抖任务提交，独立于磁盘修订号。
    private var generation: UInt64 = 0
    /// 最近一次提交的完成任务，供页面离开或进入后台时等待；尚未提交时为 `nil`。
    private(set) var operation: Task<Void, Never>?
    /// 提交前取得源文件租约的回调；返回的释放闭包在存储操作结束后于主 Actor 调用。
    var acquireFiles: (() -> (() -> Void))?
    /// 当前提交失败时在主 Actor 调用的回调；已被新提交取代的失败不再提示。
    var failed: (() -> Void)?

    /// 创建单会话协调器，不主动读取或写入磁盘。
    ///
    /// - Parameters:
    ///   - conversationID: 用于保存和删除的稳定会话标识。
    ///   - store: 支持按调用顺序入队的草稿存储实现。
    init(conversationID: String, store: any ChatDraftStoring) {
        self.conversationID = conversationID
        self.store = store
    }

    /// 取消尚未提交的防抖任务；已入队的文件操作继续执行并释放各自租约。
    deinit { pending?.cancel() }

    /// 在页面完成批量恢复后建立内容基线，避免初始化过程触发重复保存。
    ///
    /// - Parameter snapshot: 已安装到页面的内容；`nil` 表示以空草稿建立基线。
    func restored(_ snapshot: ChatDraftSnapshot?) {
        var value = snapshot ?? ChatDraftSnapshot(conversationID: conversationID)
        // 磁盘修订号不属于用户内容，不参与后续页面快照的相等比较。
        value.revision = 0
        latest = value
        submitted = value
    }

    /// 接收内容变更，普通编辑防抖 300 毫秒，清空或要求立即提交时直接入队。
    ///
    /// - Parameters:
    ///   - snapshot: 只包含已就绪附件的最新页面快照。
    ///   - immediately: 是否结束防抖并提交；默认为 `false`，附件就绪和页面离开时应传入 `true`。
    func changed(_ snapshot: ChatDraftSnapshot, immediately: Bool = false) {
        guard snapshot != latest || immediately else { return }
        latest = snapshot
        pending?.cancel()
        pending = nil
        generation &+= 1
        if immediately || snapshot.isEmpty { flush(); return }
        let revision = generation
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, generation == revision else { return }
            flush()
        }
    }

    /// 结束防抖并提交最新内容，空快照提交删除操作。
    ///
    /// 文件租约在同步入队前取得，存储完成后释放；提交失败通过 `failed` 报告。
    /// - Returns: 等待此次及此前已入队存储工作的任务；没有新内容时复用最近任务，尚无提交时为 `nil`。
    @discardableResult
    func flush() -> Task<Void, Never>? {
        pending?.cancel()
        pending = nil
        guard let latest, latest != submitted else { return operation }
        submitted = latest
        let release = acquireFiles?()
        // 保存和清空在同一顺序链中提交，旧保存不能在删除之后把草稿重新写回。
        let task = latest.isEmpty ? store.remove(conversationID: conversationID) : store.save(latest)
        operation = Task { [self] in
            defer { release?() }
            if case .failure = await task.result {
                // 只让仍代表当前内容的失败重新进入可提交状态，保留较新提交的基线。
                if submitted == latest {
                    submitted = nil
                    failed?()
                }
            }
        }
        return operation
    }
}
