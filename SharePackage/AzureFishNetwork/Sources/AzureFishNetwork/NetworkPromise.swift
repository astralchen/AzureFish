import Foundation

/// 单个等待者的取消不会影响产生结果的共享任务。
final class NetworkPromise<Value: Sendable>: @unchecked Sendable {
    /// 保护结果、等待者及提前取消标记的互斥锁。
    private let lock = NSLock()
    /// 首次确定的完成结果；nil 表示仍可登记等待者。
    private var result: Result<Value, any Error>?
    /// 按等待身份保存的未完成 continuation；完成或取消后移除。
    private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]
    /// 取消先于登记发生的等待身份，登记时消费该标记。
    private var cancelled: Set<UUID> = []

    /// 保存首次结果并恢复全部已登记等待者；后续完成调用被忽略。
    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuations = self.continuations.values
        self.continuations.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(with: result) }
    }
    /// 等待共享结果；取消只恢复当前等待者，不取消产生结果的工作。
    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled.remove(id) != nil { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else if let result { lock.unlock(); continuation.resume(with: result) }
                else { continuations[id] = continuation; lock.unlock() }
            }
        } onCancel: { self.cancel(id) }
    }
    /// 移除并取消指定等待者；尚未登记且未完成时暂存取消标记。
    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        if continuation == nil, result == nil { cancelled.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// 让操作与超时竞争首个结果，并在离开时请求取消两项任务。
///
/// - Parameters:
///   - seconds: 超时等待秒数，由注入时钟解释。
///   - clock: 可响应取消的等待机制。
///   - error: 超时先完成时抛出的错误。
///   - operation: 要执行一次的异步工作，须自行响应取消。
/// - Throws: 操作原始错误、指定超时错误或当前等待的取消错误。
///
/// 未响应取消的工作可能在本方法返回后继续执行。
func webSocketTimeout<Value: Sendable>(seconds: TimeInterval, clock: any NetworkClock,
                                       error: WebSocketError,
                                       operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let promise = NetworkPromise<Value>()
    let work = Task { do { promise.resolve(.success(try await operation())) } catch { promise.resolve(.failure(error)) } }
    let timer = Task {
        do { try await clock.sleep(seconds: seconds); try Task.checkCancellation(); promise.resolve(.failure(error)) } catch {}
    }
    defer { work.cancel(); timer.cancel() }
    return try await promise.value()
}

/// 等待共享任务；取消当前等待不会取消共享工作。
public func waitForSharedNetworkTask<Value: Sendable>(_ task: Task<Value, any Error>) async throws -> Value {
    let promise = NetworkPromise<Value>()
    let observer = Task { promise.resolve(await task.result) }
    defer { observer.cancel() }
    return try await promise.value()
}
