import Foundation
import GRDB

/// `message_reedit_recovery` 的类型化持久记录；字段及关联由账号基线建立。
struct ReeditRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_reedit_recovery`。
    static let databaseTableName = "message_reedit_recovery"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    var operationID: String
    /// 恢复副本状态：pending、confirmed 或 expired。
    var state: String
    /// 可恢复的原消息文字；非文字消息或副本过期后为 nil。
    var text: String?
    /// 重新编辑副本的截止时间，采用 Unix 秒时间戳。
    var expires: Double
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case operationID = "operation_id"
        case state = "state"
        case text = "text"
        case expires = "expires"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case operationID = "operation_id"
        case state = "state"
        case text = "text"
        case expires = "expires"
    }
    /// 在调用者的基线迁移事务中创建 `message_reedit_recovery` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text)
            t.column("conversation_id", .text).notNull()
            t.column("operation_id", .text).notNull()
            t.column("state", .text).notNull()
            t.column("text", .text)
            t.column("expires", .double).notNull()
        }
    }
}
