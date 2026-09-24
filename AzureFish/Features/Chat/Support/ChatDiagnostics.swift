import Foundation
import OSLog

/// 聊天诊断仅由本次进程的显式启动参数开启，不读取持久化偏好。
nonisolated enum ChatDiagnostics {
    /// Debug 构建传入 `-chat-debug-logs true` 才启用；Release 始终关闭。
    static let isEnabled: Bool = {
        #if DEBUG
        return isEnabled(arguments: ProcessInfo.processInfo.arguments)
        #else
        return false
        #endif
    }()

    /// 只接受唯一参数及紧随其后的字面值 `true`，缺值、重复或其他值均关闭。
    static func isEnabled(arguments: [String]) -> Bool {
        let indices = arguments.indices.filter { arguments[$0] == "-chat-debug-logs" }
        guard indices.count == 1, let index = indices.first,
              arguments.indices.contains(index + 1) else { return false }
        return arguments[index + 1] == "true"
    }

    /// 与聊天错误日志共用系统日志设施，保留诊断标记以便控制台筛选。
    private static let logger = Logger(subsystem: "AzureFish.Chat", category: "Diagnostics")

    /// 关闭时不构造消息，避免高频滚动诊断影响布局与动画时序。
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }
}
