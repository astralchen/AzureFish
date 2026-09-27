import Foundation

/// 单个等待者的取消不会影响产生结果的共享任务。
final class NetworkPromise<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuations: [UUID: CheckedContinuation<Value, any Error>] = [:]
    private var cancelled: Set<UUID> = []

    func resolve(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuations = self.continuations.values
        self.continuations.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.resume(with: result) }
    }
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
    private func cancel(_ id: UUID) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        if continuation == nil, result == nil { cancelled.insert(id) }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

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
