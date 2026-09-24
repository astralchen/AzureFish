import Foundation

/// 按登记顺序调度异步操作，并限制同时运行的任务数量。
///
/// `addTask` 返回独立的原生 Task；`withTask` 等待受管任务并向其传播调用方取消。
/// 取消是协作式的：已运行任务实际退出前始终占用槽位。相同队列内嵌套等待仍
/// 受同一上限约束，不提供重入豁免；同步重处理应自行选择合适的执行上下文。
///
/// 操作保留自身的 Actor 隔离，并继承原生任务的优先级和任务局部值。并发限制
/// 不会将同步工作自动转移到后台。队列销毁时会取消其持有的任务。
///
/// - Important: 线程安全依赖锁保护全部可变队列状态；许可使用独立锁。
///   队列锁内不得执行操作、取消任务或恢复 continuation，以允许取消处理器重入。
final class TaskQueue: @unchecked Sendable {
    /// 一次性许可，允许先决定结果再进入等待；只会恢复一次 continuation。
    private final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var continuation: CheckedContinuation<Void, Error>?

        /// 等待许可；若终态已确定，直接恢复该结果。
        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                let result = self.result
                if result == nil { self.continuation = continuation }
                lock.unlock()
                if let result { continuation.resume(with: result) }
            }
        }

        /// 确定首次终态，忽略随后到达的许可或取消通知。
        func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    /// 擦除结果类型，只保存调度与取消所需的原生句柄操作。
    private struct Entry: Sendable {
        let id: UUID
        let permit: Permit
        let cancel: @Sendable () -> Void
        let isCancelled: @Sendable () -> Bool
    }

    /// 锁内提交状态、锁外发送通知，使取消回调可安全重入队列。
    private struct Resolution {
        let permit: Permit
        let result: Result<Void, Error>

        func apply() { permit.resolve(result) }
    }

    /// 同时持有执行许可的任务数量上限；创建后不可更改。
    let maxConcurrentTasks: Int
    private let lock = NSLock()
    private var pending: [Entry] = []
    private var running: [UUID: Entry] = [:]

    /// 已获得许可的任务数，包括收到取消但尚未实际退出的任务。
    var runningCount: Int { locked { running.count } }
    /// 尚未获得许可的任务数。
    var pendingCount: Int { locked { pending.count } }

    /// 创建具有固定并发上限的异步任务队列。
    ///
    /// - Parameter maxConcurrentTasks: 同时运行的任务数量上限，必须大于零。
    init(maxConcurrentTasks: Int) {
        precondition(maxConcurrentTasks > 0)
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    deinit { cancelAll() }

    /// 将异步操作加入队列，并立即返回原生任务句柄。
    ///
    /// 登记顺序决定执行许可的发放顺序；不同 Actor 上的实际开始顺序由 Swift 调度。
    /// 提交方取消不会自动取消已提交的任务；请取消返回的句柄，或调用 `cancelAll()`。
    ///
    /// 等待许可或进入操作所属 Actor 前取消时，任务以 `CancellationError` 结束，
    /// 不会调用操作闭包。操作开始后采用协作式取消，并保留操作实际返回的结果。
    ///
    /// - Parameters:
    ///   - priority: 传递给原生任务的优先级。默认值为 `nil`，沿用原生继承规则；不改变排队顺序。
    ///   - operation: 获得许可后执行的操作，保留闭包自身的 Actor 隔离。
    /// - Returns: 可用于等待结果或请求取消的任务。即使操作不抛错，任务的错误类型仍为 `Error`。
    @discardableResult
    func addTask<Success: Sendable>(
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, Error> {
        let id = UUID()
        let permit = Permit()
        let action = Operation(operation)
        let operationIsolation = action.isolation
        let task = Task(priority: priority) { [weak self] in
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await permit.wait()
                try Task.checkCancellation()
                return try await Self.execute(isolation: operationIsolation, operation: action)
            } onCancel: { [weak self] in
                self?.cancelWaiting(id)
                // 若取消早于登记或许可等待，结果仍由 Permit 保留。
                permit.resolve(.failure(CancellationError()))
            }
        }
        let resolutions = locked {
            pending.append(Entry(id: id, permit: permit,
                                 cancel: { task.cancel() }, isCancelled: { task.isCancelled }))
            return drainLocked()
        }
        resolutions.forEach { $0.apply() }
        // 不跨 await 强持有队列；销毁队列仍能取消全部任务。
        Task { [weak self] in
            _ = await task.result
            self?.finish(id)
        }
        return task
    }

    /// `sending` 将闭包独占转交给此不可变容器；只有对应受管任务调用它一次。
    private struct Operation<Success: Sendable>: @unchecked Sendable {
        let body: @isolated(any) () async throws -> Success
        let isolation: (any Actor)?

        init(_ operation: sending @escaping @isolated(any) () async throws -> Success) {
            let body: @isolated(any) () async throws -> Success = operation
            self.body = body
            self.isolation = body.isolation
        }
    }

    /// 先进入操作所属 Actor，再检查取消，避免许可检查与 Actor 切换之间漏掉取消。
    private static func execute<Success: Sendable>(
        isolation: isolated (any Actor)?,
        operation: Operation<Success>
    ) async throws -> Success {
        try Task.checkCancellation()
        return try await operation.body()
    }

    /// 将异步操作加入队列，并等待其结果。
    ///
    /// 本方法与 `addTask(priority:operation:)` 共用并发预算。内部操作运行在独立任务中，
    /// 不与调用方共享任务身份。调用方取消会传递给内部任务；即使操作忽略取消，
    /// 本方法仍等待该任务实际退出。操作开始后的成功或业务错误不会被迟到的取消覆盖。
    ///
    /// - Parameters:
    ///   - priority: 内部任务的优先级。默认值为 `nil`，沿用原生继承规则；不改变排队顺序。
    ///   - operation: 获得许可后执行的操作，保留闭包自身的 Actor 隔离。
    /// - Returns: 操作返回的值。
    /// - Throws: 调用方已取消或操作开始前取消时抛出 `CancellationError`；否则传播操作的错误。
    ///   调用方已取消时不会提交操作。
    func withTask<Success: Sendable>(
        priority: TaskPriority? = nil,
        @_inheritActorContext @_implicitSelfCapture
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) async throws -> Success {
        try Task.checkCancellation()
        let task = addTask(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 请求取消调用时已登记的全部任务。
    ///
    /// 本方法不等待运行任务结束。运行项实际退出前继续占用槽位；等待项立即移出
    /// 队列并解除许可等待。取消处理器重入或随后提交的新任务不属于本次取消快照。
    func cancelAll() {
        let (waiting, active) = locked {
            let waiting = pending
            pending.removeAll()
            return (waiting, Array(running.values))
        }
        for entry in waiting {
            entry.cancel()
            entry.permit.resolve(.failure(CancellationError()))
        }
        for entry in active { entry.cancel() }
    }

    /// 只删除等待项；已经获得许可的任务由终态观察者释放槽位。
    private func cancelWaiting(_ id: UUID) {
        let permit = locked {
            guard let index = pending.firstIndex(where: { $0.id == id }) else { return Optional<Permit>.none }
            return pending.remove(at: index).permit
        }
        permit?.resolve(.failure(CancellationError()))
    }

    /// 按执行身份清理已结束的任务，再为等待项分配空闲槽位。
    ///
    /// 仅由任务终态观察者调用；发出取消请求不代表任务已结束。
    private func finish(_ id: UUID) {
        let resolutions = locked {
            running[id] = nil
            // 开始等待前就取消的任务，也可能尚未收到取消处理回调。
            pending.removeAll { $0.id == id }
            return drainLocked()
        }
        resolutions.forEach { $0.apply() }
    }

    /// 仅在队列锁内调用；先分配槽位，再把许可通知交给锁外执行。
    private func drainLocked() -> [Resolution] {
        var resolutions: [Resolution] = []
        while running.count < maxConcurrentTasks, !pending.isEmpty {
            let entry = pending.removeFirst()
            if entry.isCancelled() {
                resolutions.append(Resolution(permit: entry.permit, result: .failure(CancellationError())))
            } else {
                running[entry.id] = entry
                resolutions.append(Resolution(permit: entry.permit, result: .success(())))
            }
        }
        return resolutions
    }

    /// 仅执行同步状态访问，不能在 body 内调用外部代码或等待异步工作。
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
