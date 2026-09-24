import Foundation

/// 将首期单进程 SQLite 请求串行化，锁覆盖异步事务，避免 actor 重入造成竞态。
actor DatabaseGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async throws {
        guard locked else { locked = true; return }
        guard waiters.count < 64 else { throw APIError(.tooManyRequests, "RATE_LIMITED") }
        await withCheckedContinuation { waiters.append($0) }
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer {
            if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation()
    }
}

/// 有界的进程内请求限流；仅用于单实例本机开发服务。
actor RateLimiter {
    private var buckets: [String: (count: Int, deadline: Date)] = [:]
    func check(_ key: String, limit: Int, now: Date = Date()) throws {
        if buckets.count >= 10_000 { buckets = buckets.filter { $0.value.deadline > now } }
        var bucket = buckets[key] ?? (0, now.addingTimeInterval(60))
        if bucket.deadline <= now { bucket = (0, now.addingTimeInterval(60)) }
        guard bucket.count < limit, buckets[key] != nil || buckets.count < 10_000 else {
            throw APIError(.tooManyRequests, "RATE_LIMITED")
        }
        bucket.count += 1
        buckets[key] = bucket
    }
}
