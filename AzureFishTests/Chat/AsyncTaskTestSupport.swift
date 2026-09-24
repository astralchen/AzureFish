import Foundation
import Testing

/// 测试用单次信号，让断言等待明确事件而非猜测 Actor 执行次数。
@MainActor
final class TaskTestSignal {
    /// 已完成的信号对后续等待立即生效。
    private var signalled = false
    /// 等待本次事件的测试协程。
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// 等待可控事件；发送方可以在等待之前完成。
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// 只发送一次事件，恢复所有等待者。
    func signal() {
        guard !signalled else { return }
        signalled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// 可控异步任务，故意不响应取消以验证严格串行必须等待实际退出。
@MainActor
final class ControlledTaskOperation {
    /// 确认业务已获得执行机会。
    let started = TaskTestSignal()
    /// 确认挂起点已返回，可检查下一任务只能在当前退出后开始。
    let returned = TaskTestSignal()
    /// 尚未恢复的等待。
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
    /// 允许测试预先指定结果。
    private var result: Result<Void, Error>?
    /// 挂起直到测试显式提供结果，不依赖时钟推进。
    func run() async throws {
        started.signal()
        let result = if let result { result } else {
            await withCheckedContinuation { continuation = $0 }
        }
        returned.signal()
        try result.get()
    }
    /// 提供首个结果，重复完成不产生额外恢复。
    func resolve(_ result: Result<Void, Error> = .success(())) {
        guard self.result == nil else { return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}

/// 等待 UIKit 或播放器外部状态达到目标，失败有明确时限，避免固定 yield 次数。
@MainActor
func waitForTaskCondition(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("等待异步状态超过 \(timeout) 秒")
            throw URLError(.timedOut)
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
