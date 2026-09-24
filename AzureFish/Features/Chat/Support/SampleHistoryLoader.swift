import AppLocalization
import Foundation

/// 每次进入页面拥有独立来源；最新页保留完整附件样例，更早三页只包含文字。
@available(iOS 16.0, *)
@MainActor
final class SampleHistoryLoader: MessageHistoryLoading {
    /// 样例来源的参数错误；`invalidCursor` 表示游标越界、不可解析或后续页大小无效。
    private enum Failure: Error { case invalidCursor }
    /// 首屏附件使用的页面独占存储，负责导入文件及丢弃结果时的清理。
    private let store: any AttachmentStoring
    /// 将样例资源键解析为加载时应用语言的服务。
    private let localizer: Localizer
    /// 本次会话的固定时间基准，保证不同页和重试之间的消息时间一致。
    private let referenceDate: Date
    /// 可注入的挂起操作；生产演示模拟延时，测试可立即完成或控制等待。
    private let sleeper: @Sendable (Duration) async throws -> Void
    #if DEBUG
    /// 调试参数启用的一次性故障，只影响首次请求更早历史，供 UI 测试验证重试。
    private var failsNextOlderPage: Bool
    #endif

    /// 创建与当前聊天页面共享附件目录的样例来源。
    ///
    /// - Parameters:
    ///   - store: 页面拥有的附件存储。
    ///   - localizer: 样例文字的本地化依赖，默认使用应用当前语言。
    ///   - referenceDate: 生成各页消息时间的固定基准，默认使用当前时间。
    ///   - sleeper: 接收模拟时长的可取消延时操作，每次请求传入 400 毫秒。
    init(store: any AttachmentStoring, localizer: Localizer = .live, referenceDate: Date = Date(),
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.store = store
        self.localizer = localizer
        self.referenceDate = referenceDate
        self.sleeper = sleeper
        #if DEBUG
        failsNextOlderPage = ProcessInfo.processInfo.arguments.contains("-imessage-history-fail-once")
        #endif
    }

    /// 首次返回完整类型展示集，随后通过数字游标向前读取 60 条更早的文字样例。
    ///
    /// 首屏正常包含 38 条消息，单项附件失败时沿用 `SampleChatHistory` 的跳过策略。
    /// 数字游标表示更早样例中尚未读取区间的右开边界，后续页最多返回 `limit` 条。
    ///
    /// - Parameters:
    ///   - cursor: `nil` 读取首屏；后续为 1...60 的十进制字符串。
    ///   - limit: 后续页的最大条数；首屏始终保留完整的类型展示集。
    /// - Returns: 有稳定来源身份和时间的样例页；更早区间读完后游标为 `nil`。
    /// - Throws: 无效分页参数、样例资源准备错误、调试故障或取消错误。
    func loadPage(before cursor: String?, limit: Int) async throws -> HistoryPage {
        try await sleeper(.milliseconds(400))
        try Task.checkCancellation()
        if let cursor {
            guard let end = Int(cursor), (1...60).contains(end), limit > 0 else {
                throw Failure.invalidCursor
            }
            #if DEBUG
            if failsNextOlderPage {
                failsNextOlderPage = false
                throw URLError(.networkConnectionLost)
            }
            #endif
            // 从区间末端向前切页，页内仍按时间正序交付，供模型直接插入列表开头。
            let start = max(0, end - limit)
            let messages = (start..<end).map { index in
                let text = localizer.text("imessage.history.sample", index + 1)
                let content: MessageContent = index.isMultiple(of: 5)
                    ? .richText(.init(runs: [.init(text, style: [.bold, .italic]),
                                           .init("\n" + localizer.text("imessage.seed.text.plain"))]))
                    : .userText(text)
                // 六分钟的间隔超过时间分组阈值；最晚的更早样例仍早于首屏全部消息。
                return HistoryMessage(sourceID: "older-\(index)",
                    sentAt: referenceDate.addingTimeInterval(Double(index - 60) * 360 - 38),
                    direction: index.isMultiple(of: 2) ? .incoming : .outgoing, content: content)
            }
            return HistoryPage(messages: messages, nextCursor: start == 0 ? nil : String(start))
        }
        // 最新页是完整的类型展示集，正常入口以 38 为 limit；失败的单项仍沿用样例降级策略。
        let entries = try await SampleChatHistory.load(store: store, localizer: localizer)
        let page = HistoryPage(messages: entries.enumerated().map { index, entry in
            HistoryMessage(sourceID: "initial-\(index)",
                sentAt: referenceDate.addingTimeInterval(Double(index - entries.count)),
                direction: entry.direction, content: entry.content)
        }, nextCursor: "60")
        // 资源构建结束后再次检查取消，避免交付前的取消留下已导入文件。
        if Task.isCancelled { discard(page); throw CancellationError() }
        return page
    }

    /// 删除未接收页面中的本地附件；更早的纯文字页不需要文件清理。
    ///
    /// - Parameter page: 尚未加入会话、其附件仍由本次加载独占的结果。
    func discard(_ page: HistoryPage) {
        for message in page.messages {
            if case .attachment(let attachment) = message.content {
                attachment.localFileURLs.forEach { store.removeFile(at: $0) }
            }
        }
    }
}
