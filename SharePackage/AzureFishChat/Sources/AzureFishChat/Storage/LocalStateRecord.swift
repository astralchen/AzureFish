import Foundation
import GRDB

/// `conversation_local_state` 的类型化持久记录；字段及关联由账号基线建立。
struct LocalStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_local_state`。
    static let databaseTableName = "conversation_local_state"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 会话是否曾因可见聊天内容、发送或草稿进入列表。
    var appeared: Bool
    /// 本机隐藏会话时的序列边界；nil 表示未隐藏。
    var hiddenThrough: Int64?
    /// 当前账号在本机是否为会话设置手动未读提醒，不修改服务端已读水位。
    var manuallyUnread: Bool
    /// 最近聊天活动时间，采用 Unix 毫秒时间戳；草稿修改不推进此值。
    var activityAt: Int64
    /// 已完成列表检查的最新序列；-1 表示尚未检查。
    var inspectedThrough: Int64
    /// 已完成列表检查的可见边界版本；-1 表示尚未检查。
    var inspectedBoundary: Int64
    /// 本机清空历史时记录的序列上界，后续同步不得恢复此范围的显示。
    var clearedThrough: Int64
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case appeared = "appeared"
        case hiddenThrough = "hidden_through"
        case manuallyUnread = "manually_unread"
        case activityAt = "activity_at"
        case inspectedThrough = "inspected_through"
        case inspectedBoundary = "inspected_boundary"
        case clearedThrough = "cleared_through"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case appeared = "appeared"
        case hiddenThrough = "hidden_through"
        case manuallyUnread = "manually_unread"
        case activityAt = "activity_at"
        case inspectedThrough = "inspected_through"
        case inspectedBoundary = "inspected_boundary"
        case clearedThrough = "cleared_through"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_local_state` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("conversation_id", .text)
            t.column("appeared", .integer).notNull()
            t.column("hidden_through", .integer)
            t.column("manually_unread", .integer).notNull()
            t.column("activity_at", .integer).notNull()
            t.column("inspected_through", .integer).notNull()
            t.column("inspected_boundary", .integer).notNull()
            t.column("cleared_through", .integer).notNull()
        }
    }
}
