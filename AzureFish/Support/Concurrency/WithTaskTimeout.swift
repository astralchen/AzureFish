import Foundation

/// 异步操作超过期限，已请求取消并等待其退出后报告的错误。
struct TimeoutError: LocalizedError, Sendable {
    /// 用于诊断的中文说明；超时不会强制终止不响应取消的操作。
    var errorDescription: String? { "异步操作执行超时" }
}

/// 以结构化子任务竞速操作和计时；先观察到的结果获胜，返回前等待全部子任务退出。
/// 操作默认继承调用处的 Actor 隔离，也可显式指定隔离；不固定线程或自动转移到后台。
/// sending 允许安全转移独占的捕获值，操作结果须为 Sendable。
/// duration 须非负；零时长仍参与竞速，tolerance 原样交由指定 Clock 处理。
/// 取消是协作式的，忽略取消的操作可能使返回时间超过 duration。
@available(iOS 16.0, *)
nonisolated func withTaskTimeout<C: Clock, Success: Sendable>(
    for duration: C.Instant.Duration,
    tolerance: C.Instant.Duration? = nil,
    clock: C = .continuous,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    precondition(duration >= .zero)
    return try await runWithTaskTimeout(operation: operation) {
        try await Task.sleep(for: duration, tolerance: tolerance, clock: clock)
    }
}

/// iOS 15 的秒数兼容入口；隔离、竞速与取消语义与 Duration 入口相同。
nonisolated func withTaskTimeout<Success: Sendable>(
    seconds interval: TimeInterval,
    @_inheritActorContext operation: sending @escaping @isolated(any) () async throws -> Success
) async throws -> Success {
    precondition(interval.isFinite && interval >= 0 && interval < Double(UInt64.max) / 1_000_000_000)
    return try await runWithTaskTimeout(operation: operation) {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

/// 两个计时入口共用结构化竞速；仅 sleep 正常结束时产生 TimeoutError。
private nonisolated func runWithTaskTimeout<Success: Sendable>(
    operation: sending @escaping @isolated(any) () async throws -> Success,
    sleep: @escaping @Sendable () async throws -> Void
) async throws -> Success {
    try Task.checkCancellation()
    let operation = TimeoutOperation(operation)
    return try await withThrowingTaskGroup(of: Success.self) { group in
        group.addTask {
            try await operation.run()
        }
        group.addTask {
            try await sleep()
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        // 始终存在两个子任务；next 返回后，该已完成子任务不再参与取消。
        return try await group.next()!
    }
}

/// sending 捕获不能经任务组的非 Sendable body 再次转移；由 Actor 持有操作以安全跨越该边界。
/// 仅操作子任务调用 run；保存的闭包继续按其自身隔离执行，不固定到 MainActor。
private actor TimeoutOperation<Success: Sendable> {
    private let operation: @isolated(any) () async throws -> Success

    init(_ operation: sending @escaping @isolated(any) () async throws -> Success) {
        self.operation = operation
    }

    func run() async throws -> Success {
        try Task.checkCancellation()
        return try await operation()
    }
}
