import Foundation
import OSLog

/// 由本次进程启动参数控制的网络诊断输出，不读取持久化偏好。
struct NetworkDiagnostics: Sendable {
    private static let logger = Logger(subsystem: "AzureFish.Network", category: "HTTPClient")

    /// 生产调用使用的日志实例；Release 始终关闭，Debug 仅接受显式的 true。
    static let live = NetworkDiagnostics(enabled: isEnabled(arguments: ProcessInfo.processInfo.arguments)) { text in
        logger.debug("\(text, privacy: .public)")
    }

    private let enabled: Bool
    private let sink: @Sendable (String) -> Void

    /// 创建内部可验证的输出边界；接收器可能被多个并发请求调用，须自行保证线程安全。
    init(enabled: Bool, sink: @escaping @Sendable (String) -> Void) {
        self.enabled = enabled
        self.sink = sink
    }

    /// 根据构建配置及启动参数确定是否启用；参数必须唯一且紧随小写字面值 true。
    static func isEnabled(arguments: [String]) -> Bool {
        #if DEBUG
        let indices = arguments.indices.filter { arguments[$0] == "-AzureFishNetworkLogging" }
        guard indices.count == 1, let index = indices.first,
              arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == "true"
        #else
        return false
        #endif
    }

    /// 启用时读取单调时钟；关闭时不采集计时信息，返回 nil。
    func startTime() -> UInt64? {
        enabled ? DispatchTime.now().uptimeNanoseconds : nil
    }

    /// 输出一条诊断；关闭时不求值消息，消息只能由已筛选的诊断字段构造。
    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        sink(message())
    }

    /// 计算从指定单调时钟读数起经过的毫秒数；没有起点时返回 0。
    static func elapsedMilliseconds(since start: UInt64?) -> UInt64 {
        guard let start else { return 0 }
        return (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// 只映射明确允许的错误分类，不访问底层描述、URL 或 userInfo。
    static func errorCode(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "transport(\(error.code.rawValue))" }
        guard let error = error as? NetworkError else { return "unknown" }
        switch error {
        case .invalidRequest: return "invalidRequest"
        case .insecureURL: return "insecureURL"
        case .nonHTTPResponse: return "nonHTTPResponse"
        case .responseTooLarge: return "responseTooLarge"
        case .transport(let code): return "transport(\(code.rawValue))"
        case .transportFailed: return "transportFailed"
        }
    }
}
