import Foundation
import GRDB

/// `message_send_task` 的类型化持久记录；字段及关联由账号基线建立。
struct SendTaskRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_send_task`。
    static let databaseTableName = "message_send_task"
    /// 待发消息 UUID 的小写字符串，贯穿服务端确认。
    var id: String
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    var clientID: String
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    var operationID: String
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    var deviceID: String
    /// 待发消息的内容类型原值。
    var kind: String
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    var text: String
    /// 链接原文；nil 表示没有附带链接。
    var linkURL: String?
    /// 原值是否包含格式片段集合，用于区分 nil 与空集合。
    var hasTextRuns: Bool
    /// 发送状态原值，如 waiting、sending、confirming 或 failed。
    var state: String
    /// 消息本机入队时间，采用 Unix 秒时间戳。
    var createdAt: Double
    /// 最近记录的失败分类；nil 表示没有失败记录。
    var failure: String?
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case conversationID = "conversation_id"
        case clientID = "client_id"
        case operationID = "operation_id"
        case deviceID = "device_id"
        case kind = "kind"
        case text = "text"
        case linkURL = "link_url"
        case hasTextRuns = "has_text_runs"
        case state = "state"
        case createdAt = "created_at"
        case failure = "failure"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case conversationID = "conversation_id"
        case clientID = "client_id"
        case operationID = "operation_id"
        case deviceID = "device_id"
        case kind = "kind"
        case text = "text"
        case linkURL = "link_url"
        case hasTextRuns = "has_text_runs"
        case state = "state"
        case createdAt = "created_at"
        case failure = "failure"
    }
    /// 在调用者的基线迁移事务中创建 `message_send_task` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("conversation_id", .text).notNull()
            t.column("client_id", .text).notNull()
            t.column("operation_id", .text).notNull()
            t.column("device_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("text", .text).notNull()
            t.column("link_url", .text)
            t.column("has_text_runs", .integer).notNull()
            t.column("state", .text).notNull()
            t.column("created_at", .double).notNull()
            t.column("failure", .text)
        }
    }
}
