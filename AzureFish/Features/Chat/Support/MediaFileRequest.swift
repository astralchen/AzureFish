import os
import Foundation

/// 桥接系统文件回调的锁保护状态机；只把复制后的自有 URL 交给异步处理。
///
/// `@unchecked Sendable` 仅用于 Foundation 回调边界；全部可变状态均由 lock 保护。
nonisolated final class MediaFileRequest: @unchecked Sendable {
    /// 系统尚未返回、正在复制和终态；完成回调最多执行一次。
    private enum Phase { case waiting, copying, finished }
    /// 保护取消、回调与同步复制之间的竞争。
    private let lock = NSLock()
    /// 当前请求阶段。
    private var phase: Phase = .waiting
    /// 复制中收到取消时延迟到复制返回再完成。
    private var cancelled = false
    /// 系统可取消进度。
    private var progress: Progress?
    /// 实际复制结束或未开始即取消时通知控制器。
    private let completion: @Sendable ((any Error)?) -> Void

    /// 创建单次请求，不拥有页面或草稿对象。
    init(completion: @escaping @Sendable ((any Error)?) -> Void) { self.completion = completion }

    /// 启动系统文件请求；即使提供者同步回调也不会重复完成。
    func start(provider: NSItemProvider, typeIdentifier: String, destination: URL) -> Progress {
        let value = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [self] source, error in
            lock.lock()
            guard phase == .waiting else { lock.unlock(); return }
            phase = .copying
            lock.unlock()
            let interval = MediaPerformance.signposter.beginInterval("ProviderFileCopy", id: MediaPerformance.signposter.makeSignpostID())
            defer { MediaPerformance.signposter.endInterval("ProviderFileCopy", interval) }
            var failure = error
            if failure == nil, let source {
                do { try FileManager.default.copyItem(at: source, to: destination) }
                catch { failure = error }
            } else if failure == nil { failure = CocoaError(.fileReadUnknown) }
            lock.lock()
            if cancelled { failure = CancellationError() }
            phase = .finished
            progress = nil
            lock.unlock()
            completion(failure)
        }
        lock.lock()
        if phase != .finished { progress = value }
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { value.cancel() }
        return value
    }

    /// 尚未复制即可立即完成取消；复制中保留槽位，防止清理早于文件写入完成。
    func cancel() {
        lock.lock()
        cancelled = true
        let finishNow = phase == .waiting
        if finishNow { phase = .finished }
        let value = progress
        if finishNow { progress = nil }
        lock.unlock()
        // 先使状态终结，再调用可能同步触发回调的系统取消。
        value?.cancel()
        if finishNow { completion(CancellationError()) }
    }
}
