import Foundation

/// 同进程账号资源共享底层下载；每个调用方保留独立取消和授权责任。
actor ChatDownloadCoordinator {
    static let shared = ChatDownloadCoordinator()
    private struct Waiter {
        let owner: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    private struct Entry {
        let id: UUID
        let task: Task<Void, Never>
        var owners: Set<UUID>
        var waiters: [UUID: Waiter]
    }
    private var entries: [String: Entry] = [:]
    private var requests: [UUID: String] = [:]

    func download(key: String, owner: UUID, request: UUID,
                  operation: @escaping @Sendable () async throws -> UUID) async throws -> UUID {
        // 最后一个调用方取消后，等待旧写入退出再使用同一缓存身份。
        if let old = entries[key], old.waiters.isEmpty { await old.task.value }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var entry = entries[key] {
                    entry.owners.insert(owner)
                    entry.waiters[request] = Waiter(owner: owner, continuation: continuation)
                    entries[key] = entry
                } else {
                    let id = UUID()
                    let task = Task {
                        let result: Result<UUID, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        self.finish(key: key, id: id, result: result)
                    }
                    entries[key] = Entry(id: id, task: task, owners: [owner],
                                         waiters: [request: Waiter(owner: owner, continuation: continuation)])
                }
                requests[request] = key
            }
        } onCancel: { Task { await self.cancel(request) } }
    }
    private func cancel(_ request: UUID) {
        guard let key = requests.removeValue(forKey: request), var entry = entries[key],
              let waiter = entry.waiters.removeValue(forKey: request) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        entries[key] = entry
        if entry.waiters.isEmpty { entry.task.cancel() }
    }
    /// 取消此页面队列的等待；其他窗口仍有调用方时保留底层任务。
    func cancelAndDrain(owner: UUID) async {
        var draining: [Task<Void, Never>] = []
        for key in Array(entries.keys) {
            guard let entry = entries[key], entry.owners.contains(owner) else { continue }
            for (id, waiter) in entry.waiters where waiter.owner == owner { cancel(id) }
            if let remaining = entries[key], remaining.waiters.isEmpty {
                remaining.task.cancel(); draining.append(remaining.task)
            }
        }
        for task in draining { await task.value }
    }
    private func finish(key: String, id: UUID, result: Result<UUID, Error>) {
        guard let entry = entries[key], entry.id == id else { return }
        entries[key] = nil
        for (id, waiter) in entry.waiters {
            requests[id] = nil; waiter.continuation.resume(with: result)
        }
    }
}
