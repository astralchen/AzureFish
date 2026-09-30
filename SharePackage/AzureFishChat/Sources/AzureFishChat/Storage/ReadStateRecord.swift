import Foundation
import GRDB

/// `conversation_read_state` 的类型化持久记录；字段及关联由账号基线建立。
struct ReadStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_read_state`。
    static let databaseTableName = "conversation_read_state"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 当前账号已读到的会话序列，包含此序列。
    var read: Int64
    /// 当前账号已确认送达到的会话序列，包含此序列。
    var delivered: Int64
    /// 服务端计算的未读消息数量。
    var unread: Int64
    /// 该未读摘要所覆盖的会话序列。
    var through: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    var revision: Int64
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case read = "read"
        case delivered = "delivered"
        case unread = "unread"
        case through = "through"
        case revision = "revision"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case read = "read"
        case delivered = "delivered"
        case unread = "unread"
        case through = "through"
        case revision = "revision"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_read_state` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("conversation_id", .text).references("conversation", column: "id", onDelete: .cascade)
            t.column("read", .integer).notNull()
            t.column("delivered", .integer).notNull()
            t.column("unread", .integer).notNull()
            t.column("through", .integer).notNull()
            t.column("revision", .integer).notNull()
        }
    }
}
