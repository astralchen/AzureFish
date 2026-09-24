import Foundation

/// 数据源交付的原始历史消息；来源身份独立于会话内分配的本地消息 ID。
nonisolated struct HistoryMessage: Sendable {
    /// 在同一来源与会话中保持稳定的标识符，用于跨页去重和保留已删除记录的身份。
    let sourceID: String
    /// 消息原始发送时间，用于按真实时间重建时间分隔项。
    let sentAt: Date
    /// 相对于当前用户的收发方向。
    let direction: MessageDirection
    /// 保留文字格式和附件元数据的原始载荷，不经过发送或模拟回复流程。
    let content: MessageContent
}

/// 一次历史请求返回的消息与后续分页位置。
nonisolated struct HistoryPage: Sendable {
    /// 按时间从早到晚排列的消息；更早页中的新记录应位于已加载消息之前。
    let messages: [HistoryMessage]
    /// 下一批更早记录的来源游标；`nil` 表示历史已全部加载。
    let nextCursor: String?
}

/// 可替换的历史数据来源，负责解释游标并管理尚未交付的资源。
///
/// 取消时应回收仍由来源持有的临时资源；已返回的迟到结果由调用方通过 `discard(_:)` 回收。
@MainActor
protocol MessageHistoryLoading {
    /// 获取最新消息或指定游标之前的一页历史。
    ///
    /// - Parameters:
    ///   - cursor: 上次成功结果提供的游标；`nil` 表示首次读取最新记录。
    ///   - limit: 请求的页大小；聊天页首次传入 38，后续传入 20。
    /// - Returns: 从早到晚排列的消息，以及下一页游标。
    /// - Throws: 加载失败或任务取消产生的错误；失败时调用方保留原游标以供重试。
    func loadPage(before cursor: String?, limit: Int) async throws -> HistoryPage

    /// 回收已返回但未被会话接收的页面，只能删除此页独占的资源。
    ///
    /// - Parameter page: 因请求取消、页面释放或请求代次失效而未被接收的结果。
    func discard(_ page: HistoryPage)
}

/// 为不持有页面独占资源的数据源提供默认回收行为。
extension MessageHistoryLoading {
    /// 无需资源清理时不执行操作；创建临时附件的数据源应自行实现回收。
    func discard(_ page: HistoryPage) {}
}

/// 历史请求的生命周期状态，同时决定顶部提示和自动加载是否可用。
nonisolated enum HistoryLoadingState: Equatable, Hashable, Sendable {
    /// - `disabled`：未启用历史来源，不显示顶部状态项。
    /// - `idle`：可请求首批或下一页历史。
    /// - `loading`：已有请求进行中，拒绝重复加载。
    /// - `failed`：当前页失败，等待用户显式重试。
    /// - `exhausted`：没有更早记录，不再发出请求。
    case disabled, idle, loading, failed, exhausted
}

/// 已解析本地化文案的顶部状态项；加载状态与文字共同构成刷新身份。
nonisolated struct HistoryStatusPresentation: Equatable, Hashable, Sendable {
    /// 控制加载指示、重试交互和辅助功能语义的状态。
    let state: HistoryLoadingState
    /// 当前应用语言下可直接显示的状态文案。
    let text: String
}
