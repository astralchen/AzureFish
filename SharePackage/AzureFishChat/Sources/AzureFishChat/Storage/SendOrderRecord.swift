import Foundation
import GRDB

/// `conversation_send_order` 的类型化持久记录；字段及关联由账号基线建立。
struct SendOrderRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_send_order`。
    static let databaseTableName = "conversation_send_order"
    /// 账号发送顺序表的自增位置；插入前为 nil，由数据库分配。
    var position: Int64?
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    enum CodingKeys: String, CodingKey {
        case position = "position"
        case messageID = "message_id"
        case conversationID = "conversation_id"
    }
    enum Columns: String, ColumnExpression {
        case position = "position"
        case messageID = "message_id"
        case conversationID = "conversation_id"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_send_order` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.autoIncrementedPrimaryKey("position")
            t.column("message_id", .text).notNull().unique()
            t.column("conversation_id", .text).notNull()
        }
        try db.create(index: "idx_conversation_send_order_0", on: databaseTableName, columns: ["conversation_id", "position"])
    }
}
