import Foundation
import GRDB

/// `conversation_member_interval` 的类型化持久记录；字段及关联由账号基线建立。
struct MemberIntervalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_member_interval`。
    static let databaseTableName = "conversation_member_interval"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 成员在会话成员集合中从 0 开始的位置。
    var memberPosition: Int
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 成员可见消息区间的起始序列，包含此序列。
    var joined: Int64
    /// 成员可见消息区间的结束序列，不包含此序列；0 表示没有结束边界。
    var left: Int64
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case memberPosition = "member_position"
        case position = "position"
        case joined = "joined"
        case left = "left"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case memberPosition = "member_position"
        case position = "position"
        case joined = "joined"
        case left = "left"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_member_interval` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("conversation_id", .text).notNull().references("conversation", column: "id", onDelete: .cascade)
            t.column("member_position", .integer).notNull()
            t.column("position", .integer).notNull()
            t.column("joined", .integer).notNull()
            t.column("left", .integer).notNull()
            t.foreignKey(["conversation_id", "member_position"], references: "conversation_member", columns: ["conversation_id", "position"], onDelete: .cascade)
            t.primaryKey(["conversation_id", "member_position", "position"])
        }
    }
}
