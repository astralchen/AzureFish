import Foundation

/// 本地 Demo 的送达边界。返回成功仅代表模拟收件端确认，不等于真实网络或 Apple 回执。
@MainActor
protocol MessageSending: AnyObject {
    /// 异步发送一条消息，并在模拟收件端确认后返回。
    ///
    /// 失败或取消时抛出错误，由调用方更新消息发送状态。
    func send(_ message: Message) async throws
}

/// 提供延时确认、附件可读性检查和可选单次故障的本地消息发送器。
@available(iOS 16.0, *)
@MainActor
final class SimulatedMessageSender: MessageSending {
    /// 指示下一次发送是否应模拟失败的布尔值；请求挂起前消耗此标记。
    private var failsNextSend: Bool

    /// 创建模拟发送器，并指定是否使首次发送失败；默认不模拟失败。
    init(failsNextSend: Bool = false) {
        self.failsNextSend = failsNextSend
    }

    /// 创建页面使用的模拟发送器，调试构建可通过启动参数启用首次失败。
    static func liveDemo() -> SimulatedMessageSender {
        #if DEBUG
        return .init(failsNextSend: ProcessInfo.processInfo.arguments.contains("-imessage-fail-first-send"))
        #else
        return .init()
        #endif
    }

    /// 等待模拟发送延时，检查一次性故障及附件文件可读性。
    ///
    /// 成功返回仅表示本地演示确认；失败和取消向调用方抛出错误。
    func send(_ message: Message) async throws {
        // 在挂起之前消耗故障开关，批量发送时仅使第一条失败。
        let fails = failsNextSend
        failsNextSend = false
        try await Task.sleep(for: .milliseconds(250))
        if fails { throw CocoaError(.fileWriteUnknown) }
        if case .attachment(let attachment) = message.content,
           !attachment.localFileURLs.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }
}
