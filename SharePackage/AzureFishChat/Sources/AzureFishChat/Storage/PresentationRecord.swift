import Foundation
import GRDB

/// `message_presentation_cache` 的类型化持久记录；字段及关联由账号基线建立。
struct PresentationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_cache`。
    static let databaseTableName = "message_presentation_cache"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 编辑器结构格式版本，当前支持 1。
    var version: Int
    /// 编辑器 UInt64 修订计数的十进制字符串，读取时须可解析。
    var revision: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case version = "version"
        case revision = "revision"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case version = "version"
        case revision = "revision"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_cache` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text)
            t.column("conversation_id", .text).notNull()
            t.column("version", .integer).notNull()
            t.column("revision", .text).notNull()
        }
    }
}
