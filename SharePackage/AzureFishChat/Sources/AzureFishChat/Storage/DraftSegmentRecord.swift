import Foundation
import GRDB

/// `conversation_draft_segment` 的类型化持久记录；字段及关联由账号基线建立。
struct DraftSegmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_draft_segment`。
    static let databaseTableName = "conversation_draft_segment"
    /// 所属编辑器草稿的会话身份，用于连接草稿根记录。
    var ownerID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 编辑片段种类，区分 text、richText 和 attachment。
    var kind: String
    /// 纯文字片段正文；其他片段种类为 nil。
    var text: String?
    /// 附件片段所引用的 UUID 字符串；其他片段种类为 nil。
    var attachmentID: String?
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case position = "position"
        case kind = "kind"
        case text = "text"
        case attachmentID = "attachment_id"
    }
    enum Columns: String, ColumnExpression {
        case ownerID = "owner_id"
        case position = "position"
        case kind = "kind"
        case text = "text"
        case attachmentID = "attachment_id"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_draft_segment` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("owner_id", .text).notNull().references("conversation_draft", column: "conversation_id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("text", .text)
            t.column("attachment_id", .text)
            t.primaryKey(["owner_id", "position"])
        }
    }
}
