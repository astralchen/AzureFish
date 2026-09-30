import Foundation
import GRDB

/// `conversation_draft_upload_item` 的类型化持久记录；字段及关联由账号基线建立。
struct DraftUploadItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_draft_upload_item`。
    static let databaseTableName = "conversation_draft_upload_item"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 媒体资产创建动作的固定 UUID 字符串。
    var id: String
    /// 上传条目的媒体种类原值。
    var kind: String
    /// 服务端媒体资产身份；nil 表示尚未记录创建结果。
    var assetID: String?
    /// 提交媒体资产完成动作的固定幂等身份。
    var completeID: String
    /// 提交媒体资产取消动作的固定幂等身份。
    var cancelID: String
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case position = "position"
        case id = "id"
        case kind = "kind"
        case assetID = "asset_id"
        case completeID = "complete_id"
        case cancelID = "cancel_id"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case position = "position"
        case id = "id"
        case kind = "kind"
        case assetID = "asset_id"
        case completeID = "complete_id"
        case cancelID = "cancel_id"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_draft_upload_item` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("conversation_id", .text).notNull().references("conversation_draft", column: "conversation_id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("asset_id", .text)
            t.column("complete_id", .text).notNull()
            t.column("cancel_id", .text).notNull()
            t.primaryKey(["conversation_id", "position"])
        }
    }
}
