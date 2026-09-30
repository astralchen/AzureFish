import Foundation
import GRDB

/// `conversation_history_range` 的类型化持久记录；字段及关联由账号基线建立。
struct HistoryRangeRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_history_range`。
    static let databaseTableName = "conversation_history_range"
    /// 覆盖区间记录的自增主键；插入前为 nil，由数据库分配。
    var id: Int64?
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 历史覆盖区间对应的成员可见边界版本。
    var boundary: Int64
    /// 已连续覆盖的起始消息序列，包含此序列。
    var lower: Int64
    /// 已连续覆盖的结束消息序列，包含此序列。
    var upper: Int64
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case conversationID = "conversation_id"
        case boundary = "boundary"
        case lower = "lower"
        case upper = "upper"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case conversationID = "conversation_id"
        case boundary = "boundary"
        case lower = "lower"
        case upper = "upper"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_history_range` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("conversation_id", .text).notNull()
            t.column("boundary", .integer).notNull()
            t.column("lower", .integer).notNull()
            t.column("upper", .integer).notNull()
        }
        try db.create(index: "idx_conversation_history_range_0", on: databaseTableName, columns: ["conversation_id", "boundary", "lower"])
    }
}
