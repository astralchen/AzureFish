import Foundation
import os

/// 页面共享的异步重处理调度器；取消同步解码时仍持有槽位直到调用实际返回。
@MainActor
final class MediaWorkScheduler {
    /// 正常页面使用已验证的默认值；只有专用性能构建允许启动参数覆盖为 1 或 2。
    static var pageLimit: Int {
        #if MEDIA_BENCHMARK
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-media-work-limit"), arguments.indices.contains(index + 1),
           let value = Int(arguments[index + 1]), (1...2).contains(value) { return value }
        #endif
        return 2
    }
    /// 可见缩略图和原图优先于后台导入，同类请求按进入顺序执行。
    nonisolated enum Kind: Int, Sendable {
        case visible, original, importing
    }
    /// 等待槽位的任务及其恢复入口。
    private struct Waiter {
        /// 单次等待身份。
        let id: UUID
        /// 调度类别。
        let kind: Kind
        /// 槽位可用或取消后恰好恢复一次。
        let continuation: CheckedContinuation<Void, Error>
    }
    /// 全部重处理的并发上限。
    private let limit: Int
    /// 正在占用槽位的任务。
    private var running: [UUID: Kind] = [:]
    /// 尚未获得槽位的有序任务。
    private var waiters: [Waiter] = []
    /// 供生命周期验证的实际运行数量。
    var activeCount: Int { running.count }
    /// 供取消验证的排队数量。
    var waitingCount: Int { waiters.count }

    /// 创建指定并发上限的调度器；页面默认值由 pageLimit 统一提供。
    init(limit: Int = 2) { self.limit = max(1, limit) }

    /// 异步等待执行机会；取消排队不阻塞线程，运行中取消不会提前释放槽位。
    func run<T: Sendable>(kind: Kind, operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let waitInterval = MediaPerformance.signposter.beginInterval("MediaQueueWait", id: MediaPerformance.signposter.makeSignpostID(), "kind=\(kind.rawValue)")
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append(Waiter(id: id, kind: kind, continuation: continuation))
                    drain()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancelWaiting(id) }
            }
        } catch {
            MediaPerformance.signposter.endInterval("MediaQueueWait", waitInterval)
            throw error
        }
        MediaPerformance.signposter.endInterval("MediaQueueWait", waitInterval)
        defer { running[id] = nil; drain() }
        try Task.checkCancellation()
        let result = try await operation()
        try Task.checkCancellation()
        return result
    }

    /// 删除等待任务；已经开始的任务由其执行体检查取消。
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// 选择有空闲槽位的最高优先级任务；完整原图始终最多一项。
    private func drain() {
        while running.count < limit {
            let candidates = waiters.indices.filter {
                waiters[$0].kind != .original || !running.values.contains(.original)
            }
            guard let index = candidates.min(by: {
                let a = waiters[$0].kind == .importing ? 1 : 0
                let b = waiters[$1].kind == .importing ? 1 : 0
                return a == b ? $0 < $1 : a < b
            }) else { return }
            let waiter = waiters.remove(at: index)
            running[waiter.id] = waiter.kind
            waiter.continuation.resume()
        }
    }
}
