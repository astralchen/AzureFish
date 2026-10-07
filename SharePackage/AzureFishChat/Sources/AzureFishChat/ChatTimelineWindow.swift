import AzureFishAPI
import Foundation
import GRDB

/// 保留已加载时间线的最早序号；新消息刷新不缩回最新单页。
public struct ChatTimelineWindow: Sendable {
    public private(set) var lowerBound: Int64?
    public init() {}

    /// 扩展已加载范围；空页不改变范围，服务端是否还有历史仍由历史游标决定。
    public mutating func include(_ messages: [ChatMessage]) {
        guard let first = messages.map(\.sequence).min() else { return }
        lowerBound = min(lowerBound ?? first, first)
    }

    /// 返回下一次历史请求的排他上界，避开已经展示的消息。
    ///
    /// 取已加载最早序号与非零服务端游标中更早的值；两者均缺失时返回 0，读取最新一页。
    public func historyBefore(pageCursor: Int64?) -> Int64 {
        let bounds = [lowerBound, pageCursor].compactMap { $0 }.filter { $0 > 0 }
        return bounds.min() ?? 0
    }

    /// 重新读取已加载范围内的权威本机记录，同时纳入新消息及撤回变化。
    public func messages(in store: ChatStore, conversation: String) async throws -> [ChatMessage] {
        try await store.timelineMessages(conversation, from: lowerBound)
    }
}

extension ChatStore {
    /// 在同一数据库快照内分批读取已加载范围，每批最多 200 条；nil 只读取最新一批。
    public func timelineMessages(_ conversation: String, from lowerBound: Int64?) throws -> [ChatMessage] {
        try check()
        return try db.read { db in
            var values: [ChatMessage] = []
            var before = Int64.max
            repeat {
                let page = try MessageRepository.fetch(Self.visibleMessages(conversation)
                    .filter(MessageRecord.Columns.sequence < before)
                    .order(MessageRecord.Columns.sequence.desc).limit(200), in: db)
                values += page.filter { lowerBound == nil || $0.sequence >= lowerBound! }
                guard let last = page.last, let lowerBound, page.count == 200,
                      last.sequence > lowerBound else { break }
                before = last.sequence
            } while true
            return values.reversed()
        }
    }
}
