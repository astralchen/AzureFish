import Foundation
import GRDB

/// `conversation_draft` 的类型化持久记录；字段及关联由账号基线建立。
struct DraftRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_draft`。
    static let databaseTableName = "conversation_draft"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    var text: String
    /// 是否存在结构化编辑器草稿；false 时仍可能有旧版文字草稿。
    var hasEditor: Bool
    /// 编辑器结构格式版本，当前支持 1。
    var version: Int
    /// 编辑器 UInt64 修订计数的十进制字符串，读取时须可解析。
    var revision: String
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case text = "text"
        case hasEditor = "has_editor"
        case version = "version"
        case revision = "revision"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case text = "text"
        case hasEditor = "has_editor"
        case version = "version"
        case revision = "revision"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_draft` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("conversation_id", .text)
            t.column("text", .text).notNull()
            t.column("has_editor", .integer).notNull()
            t.column("version", .integer).notNull()
            t.column("revision", .text).notNull()
        }
    }
}
