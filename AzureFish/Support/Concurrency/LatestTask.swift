/// 管理主 Actor 上可被新请求替换的单个异步任务。
///
/// 新任务先使旧令牌失效，再请求取消旧任务。取消是协作式的，旧任务仍可能
/// 继续执行，因此任务体应在关键等待后调用令牌的 `checkCancellation()`。
/// 任务正常结束也会使其令牌失效；需要持续发布回调的会话应另用 `OperationScope`。
@MainActor
final class LatestTask {
    /// 当前任务的有效期，独立于其他任务槽。
    private let scope = OperationScope()
    /// 当前任务的句柄；旧任务的结束回调不得覆盖新句柄。
    private var task: Task<Void, Never>?

    /// 是否仍持有当前任务；取消后立即为 `false`，不表示底层工作已完全停止。
    var isRunning: Bool { task != nil }

    /// 当前任务的句柄快照，可用于等待本次任务完成；后续替换不会改变已取得的快照。
    ///
    /// 停止操作应调用 `cancel()`，直接取消句柄不会立即使 Scope 失效。
    var currentTask: Task<Void, Never>? { task }

    /// 创建一个没有运行任务的任务槽。
    init() {}

    /// 替换当前任务，并只向调用方报告仍有效的任务产生的非取消错误。
    ///
    /// - Parameters:
    ///   - priority: 任务优先级；为 `nil` 时使用 Swift Task 的默认继承规则。
    ///   - operation: 在主 Actor 上运行的异步操作。避免跨长时间等待强持有页面。
    ///   - onError: 当前任务失败时调用；取消和过期任务的错误不会传入此闭包。
    /// - Returns: 可供等待结束的句柄。停止整个操作应使用 `cancel()`，以立即使令牌失效。
    @discardableResult
    func run(
        priority: TaskPriority? = nil,
        operation: @escaping @MainActor (OperationScope.Token) async throws -> Void,
        onError: @escaping @MainActor (any Error) -> Void
    ) -> Task<Void, Never> {
        cancel()
        let token = scope.begin()
        let task = Task(priority: priority) { @MainActor [weak self] in
            defer { self?.finish(token) }
            do {
                try token.checkCancellation()
                try await operation(token)
            } catch is CancellationError {
                // 取消是正常终止；资源清理由任务体或其业务所有者负责。
            } catch {
                guard token.isCurrent, !Task.isCancelled else { return }
                onError(error)
            }
        }
        self.task = task
        return task
    }

    /// 立即使当前令牌失效、请求取消任务并清空句柄；不等待底层工作结束。
    func cancel() {
        scope.invalidate()
        task?.cancel()
        task = nil
    }

    /// 只清理当前任务，防止迟到的旧任务结束时覆盖新任务。
    private func finish(_ token: OperationScope.Token) {
        guard token.isCurrent else { return }
        task = nil
        scope.invalidate()
    }

    /// 释放任务槽时请求取消任务；令牌的弱 Scope 引用也随之失效。
    isolated deinit {
        task?.cancel()
    }
}
