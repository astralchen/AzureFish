import Foundation
import GRDB

/// `conversation_message_summary_text_content` 的类型化持久记录；字段及关联由账号基线建立。
struct SummaryTextRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_message_summary_text_content`。
    static let databaseTableName = "conversation_message_summary_text_content"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    var text: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case text = "text"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case text = "text"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_message_summary_text_content` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text).references("conversation_message_summary", column: "id", onDelete: .cascade)
            t.column("text", .text).notNull()
        }
    }
}
