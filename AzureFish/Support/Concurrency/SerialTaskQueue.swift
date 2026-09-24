import Foundation

/// 主 Actor 上的严格串行任务队列；取消只发出请求，当前任务实际退出后才推进。
/// 资源清理由操作自行完成；返回原生 Task，不改写操作的结果或取消语义。
@MainActor
final class SerialTaskQueue {
    /// 等待项的调度顺序，数值越小越先执行；不映射到原生 TaskPriority。
    nonisolated enum SchedulingPriority: Int, Sendable {
        /// 优先于普通和低优先级等待项，不抢占当前操作。
        case high = 0
        /// 默认级别，同级任务按提交顺序执行。
        case normal = 1
        /// 在高和普通优先级等待项之后执行，不自动提升优先级。
        case low = 2
    }

    /// 新任务提交时，按排序后的插入位置处理相邻同 key 任务。
    nonisolated enum ReplacementPolicy: Sendable {
        /// 正常排队，即使 key 相同也不替换。
        case enqueue
        /// 只替换插入位置前一个同 key 的等待项，不向前搜索。
        case replaceQueued
        /// 先检查相邻等待项；插入队首时，也可请求取消同 key 当前项并等待其退出。
        case replaceQueuedAndCurrent
    }

    /// 一次执行许可，只用于等待调度，不参与业务结果结算。
    @MainActor
    private final class Permit {
        /// 尚未获得执行许可的协程。
        private var continuation: CheckedContinuation<Void, Error>?
        /// 许可或取消可能先于等待发生，仅保存第一次决定。
        private var result: Result<Void, Error>?

        /// 等待队列许可；等待期间取消会恢复为 CancellationError。
        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation = $0 }
        }

        /// 发放许可或取消等待；迟到的重复决定不影响已经开始的操作。
        func resolve(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }
    }

    /// 不同返回类型的任务统一保存调度身份与原生取消行为。
    private struct Entry {
        /// 业务取消标识，允许多个任务共享；不用于异步回调的身份判定。
        let id: String
        /// 每次提交独立生成的执行身份，避免业务 ID 重用后旧回调清理新任务。
        let executionID: UUID
        /// 只有当前项可以获得执行许可。
        let permit: Permit
        /// 等待队列的排序依据，与 Swift Task 的执行优先级独立。
        let schedulingPriority: SchedulingPriority
        /// 非 nil 且相等时允许相邻替换；是否替换由新任务的策略决定。
        let replacementKey: String?
        /// 请求原生 Task 取消，不决定其结果或何时结束。
        let cancel: () -> Void
        /// 同步读取原生取消状态，避免尚未处理的取消通知影响排序和相邻判定。
        let isCancelled: () -> Bool
    }

    /// 当前执行槽，包含取消后仍在退出的任务。
    private var current: Entry?
    /// 按调度优先级排序的等待列表，同级保持 FIFO。
    private var pending: [Entry] = []
    /// 当前是否占用执行槽；收到取消请求不会立即变为 false。
    var isRunning: Bool { current != nil }
    /// 尚未开始的任务数量，不含当前项。
    var pendingCount: Int { pending.count }

    /// 创建可立即接收任务的队列；页面接收策略由使用方管理。
    init() {}

    /// 请求所有任务取消并解除等待；运行项通过自身取消处理异步释放资源。
    isolated deinit {
        current?.cancel()
        for entry in pending {
            entry.cancel()
            entry.permit.resolve(.failure(CancellationError()))
        }
    }

    /// 立即返回原生句柄；只有轮到本项时才调用 operation。
    /// 进入操作前检查取消，操作开始后的返回值与错误完全由操作决定。
    ///
    /// - Parameters:
    ///   - id: 业务取消标识；省略时生成唯一字符串，同 ID 任务可通过 cancel(id:) 一并请求取消。
    ///   - priority: 原生 Task 的执行优先级，不参与等待队列排序。
    ///   - schedulingPriority: 等待项的调度优先级，同级按提交顺序执行。
    ///   - replacementKey: 相邻替换的分组标识；nil 表示不参与替换匹配。
    ///   - replacementPolicy: 新任务决定的替换策略，仅检查排序后插入位置的前一项。
    ///   - operation: 实际获得许可后执行的异步操作，负责响应取消及完成资源清理。
    /// - Returns: 原生任务句柄；被替换的等待项以取消结束，当前项保留其实际执行结果。
    @discardableResult
    func addTask<Success: Sendable>(
        id: String = UUID().uuidString,
        priority: TaskPriority? = nil,
        schedulingPriority: SchedulingPriority = .normal,
        replacementKey: String? = nil,
        replacementPolicy: ReplacementPolicy = .enqueue,
        operation: @escaping @MainActor @Sendable () async throws -> Success
    ) -> Task<Success, Error> {
        // 业务 ID 可重用，内部回调始终绑定本次执行身份。
        let executionID = UUID()
        let permit = Permit()
        let task = Task(priority: priority) { @MainActor [weak self] in
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await permit.wait()
                try Task.checkCancellation()
                return try await operation()
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelWaiting(executionID)
                    permit.resolve(.failure(CancellationError()))
                }
            }
        }
        removeCancelledPending()
        // 插在第一个更低优先级项之前，使同级任务保持 FIFO。
        var insertionIndex = pending.firstIndex {
            $0.schedulingPriority.rawValue > schedulingPriority.rawValue
        } ?? pending.count
        var replacedWaiting: Entry?
        var replacedCurrent: Entry?
        if replacementPolicy != .enqueue, let replacementKey {
            if insertionIndex > 0 {
                // 只检查排序后的直接前驱，不跨过其他 key，也不要求前驱的优先级相同。
                let previousIndex = insertionIndex - 1
                if pending[previousIndex].replacementKey == replacementKey {
                    replacedWaiting = pending.remove(at: previousIndex)
                    insertionIndex = previousIndex
                }
            } else if replacementPolicy == .replaceQueuedAndCurrent,
                      current?.replacementKey == replacementKey {
                // 当前项保留执行槽；稍后只请求取消，不跳过实际退出和 defer 清理。
                replacedCurrent = current
            }
        }
        pending.insert(Entry(
            id: id,
            executionID: executionID,
            permit: permit,
            schedulingPriority: schedulingPriority,
            replacementKey: replacementKey,
            cancel: { task.cancel() },
            isCancelled: { task.isCancelled }
        ), at: insertionIndex)
        // 观察者只在原生 Task 实际结束后回传，不跨等待强持有队列。
        Task { @MainActor [weak self] in
            _ = await task.result
            self?.finish(executionID)
        }
        // 先提交完整的新状态，再调用 cancel：业务的同步取消处理可能重入添加或清空队列。
        if let replacedWaiting {
            replacedWaiting.cancel()
            replacedWaiting.permit.resolve(.failure(CancellationError()))
        }
        replacedCurrent?.cancel()
        startNextIfPossible()
        return task
    }

    /// 请求取消调用时所有同业务 ID 的任务；没有匹配项时不执行任何操作。
    /// 等待项同步移除并以 CancellationError 结束；当前项保留执行槽，等待实际退出及清理。
    ///
    /// - Parameter id: 提交任务时指定的业务标识，与相邻替换的 replacementKey 独立。
    /// - Note: 使用调用时的快照，取消回调重入后新提交的同 ID 任务不属于本次取消范围。
    func cancel(id: String) {
        let running = current?.id == id ? current : nil
        let waiting = pending.filter { $0.id == id }
        // 先完成等待队列更新，再请求取消，使同步取消回调看到完整状态。
        pending.removeAll { $0.id == id }
        for entry in waiting {
            entry.cancel()
            entry.permit.resolve(.failure(CancellationError()))
        }
        // 只操作已捕获的当前项，不重新查找业务 ID，避免取消回调中新提交的任务。
        running?.cancel()
    }

    /// 取消调用时已有的任务；之后仍可添加，新任务等待当前操作实际退出。
    func cancelAll() {
        let waiting = pending
        pending.removeAll()
        current?.cancel()
        for entry in waiting {
            entry.cancel()
            entry.permit.resolve(.failure(CancellationError()))
        }
    }

    /// 原生取消回传只按执行身份移除等待项，不释放当前槽，也不影响重用业务 ID 的任务。
    private func cancelWaiting(_ executionID: UUID) {
        guard let index = pending.firstIndex(where: { $0.executionID == executionID }) else { return }
        let entry = pending.remove(at: index)
        entry.permit.resolve(.failure(CancellationError()))
    }

    /// 清除原生句柄已取消的等待项；取消处理切回主 Actor 前也不能留下虚假的相邻项。
    private func removeCancelledPending() {
        pending.removeAll { entry in
            guard entry.isCancelled() else { return false }
            entry.permit.resolve(.failure(CancellationError()))
            return true
        }
    }

    /// 空闲时向最高调度优先级的首项发放许可；已获得许可的当前项不重新排序。
    private func startNextIfPossible() {
        removeCancelledPending()
        guard current == nil, !pending.isEmpty else { return }
        let entry = pending.removeFirst()
        current = entry
        entry.permit.resolve(.success(()))
    }

    /// 只有当前原生 Task 已实际结束，才能释放执行槽并推进。
    private func finish(_ executionID: UUID) {
        guard current?.executionID == executionID else {
            cancelWaiting(executionID)
            return
        }
        current = nil
        startNextIfPossible()
    }
}
