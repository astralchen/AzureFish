import Foundation
import Darwin
import Vapor

/// 生命周期持有单个处理循环；关闭应用时等待子进程和临时文件清理。
actor MediaRuntime {
    private var task: Task<Void, Never>?
    func start(_ service: MediaService, app: Application) {
        guard task == nil else { return }
        task = Task {
            var nextCollection = Date.distantPast
            while !Task.isCancelled {
                do {
                    if Date() >= nextCollection {
                        try await service.expire(app.db)
                        nextCollection = Date().addingTimeInterval(300)
                    }
                    try await service.collect(app.db)
                    try await service.processNext(app.db)
                } catch { app.logger.error("Media maintenance failed; pending jobs will retry.") }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    func stop() async { task?.cancel(); await task?.value; task = nil }
}
struct MediaLifecycle: LifecycleHandler {
    let service: MediaService
    func didBootAsync(_ app: Application) async throws { await service.runtime.start(service, app: app) }
    func shutdownAsync(_ app: Application) async { await service.runtime.stop() }
}
/// Process 的阻塞等待运行于独立线程；异步轮询负责超时、取消与撤回。
final class MediaProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var finished: Int32?
    init(executable: String, job: String) throws {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = [job]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in self?.lock.withLock { self?.finished = p.terminationStatus } }
        try process.run()
    }
    var status: Int32? { lock.withLock { finished } }
    func wait() { process.waitUntilExit() }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }
}
