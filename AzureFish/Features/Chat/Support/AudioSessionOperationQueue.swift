import Foundation

/// 为共享音频会话提供跨控制器的顺序执行，系统操作不占用 MainActor。
@MainActor
final class AudioSessionOperationQueue {
    /// 应用音频和附件预览共用的操作队列。
    static let shared = AudioSessionOperationQueue()
    /// 最近一次操作的结束屏障；失败也会释放下一项操作。
    private var tail: Task<Void, Never>?

    /// 立即登记操作顺序，返回可等待结果；不把调用方取消传播给已提交的系统操作。
    @discardableResult
    func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Value, Error> {
        let previous = tail
        let task = Task.detached(priority: .userInitiated) {
            await previous?.value
            return try await operation()
        }
        tail = Task.detached { _ = await task.result }
        return task
    }
}
