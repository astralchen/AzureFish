import Foundation
import GRDB

/// `conversation_local_preference` 的类型化持久记录；字段及关联由账号基线建立。
struct PreferenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation_local_preference`。
    static let databaseTableName = "conversation_local_preference"
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 当前账号在本机是否将会话置顶。
    var isPinned: Bool
    /// 当前账号在本机是否将会话设为免打扰。
    var isMuted: Bool
    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case isPinned = "is_pinned"
        case isMuted = "is_muted"
    }
    enum Columns: String, ColumnExpression {
        case conversationID = "conversation_id"
        case isPinned = "is_pinned"
        case isMuted = "is_muted"
    }
    /// 在调用者的基线迁移事务中创建 `conversation_local_preference` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("conversation_id", .text)
            t.column("is_pinned", .integer).notNull()
            t.column("is_muted", .integer).notNull()
        }
    }
}
