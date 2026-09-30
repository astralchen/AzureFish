import Foundation
import GRDB

/// `conversation_draft_upload_resource` 的类型化持久记录；字段及关联由账号基线建立。
struct DraftUploadResourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_draft_upload_resource`。
    static let databaseTableName = "conversation_draft_upload_resource"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 上传条目在父集合中从 0 开始的位置。
    var itemPosition: Int
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 所关联加密媒体资源的稳定身份。
    var resourceID: String
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    var role: String
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case itemPosition = "item_position"
        case position = "position"
        case resourceID = "resource_id"
        case role = "role"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case itemPosition = "item_position"
        case position = "position"
        case resourceID = "resource_id"
        case role = "role"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_draft_upload_resource` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("conversation_id", .text).notNull()
            t.column("item_position", .integer).notNull()
            t.column("position", .integer).notNull()
            t.column("resource_id", .text).notNull().references("media_resource", column: "id")
            t.column("role", .text).notNull()
            t.foreignKey(["conversation_id", "item_position"], references: "conversation_draft_upload_item", columns: ["conversation_id", "position"], onDelete: .cascade)
            t.primaryKey(["conversation_id", "item_position", "position"])
        }
    }
}
