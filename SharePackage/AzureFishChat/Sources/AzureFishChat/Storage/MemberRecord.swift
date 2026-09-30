import Foundation
import GRDB

/// `conversation_member` 的类型化持久记录；字段及关联由账号基线建立。
struct MemberRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_member`。
    static let databaseTableName = "conversation_member"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 会话成员的用户身份，用于关联公开用户资料。
    var userID: String
    /// 该成员是否仍处于会话的有效成员状态。
    var active: Bool
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case position = "position"
        case userID = "user_id"
        case active = "active"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case position = "position"
        case userID = "user_id"
        case active = "active"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_member` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("conversation_id", .text).notNull().references("conversation", column: "id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("user_id", .text).notNull()
            t.column("active", .integer).notNull()
            t.primaryKey(["conversation_id", "position"])
        }
    }
}
