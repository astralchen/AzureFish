import Foundation
import GRDB

/// `direct_conversation_resolution` 的类型化持久记录；字段及关联由账号基线建立。
struct ResolutionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`direct_conversation_resolution`。
    static let databaseTableName = "direct_conversation_resolution"
    /// 尚未解析服务端私聊会话的本机草稿身份。
    var localID: String
    /// 持久化的解析操作 UUID 字符串；nil 表示尚未生成操作身份。
    var operationID: String?
    /// 解析成功后的权威私聊会话身份；nil 表示尚未完成绑定。
    var conversationID: String?
    /// 私聊会话解析是否处于待确认状态。
    var pending: Bool
    enum CodingKeys: String, CodingKey {
        case localID = "local_id"
        case operationID = "operation_id"
        case conversationID = "conversation_id"
        case pending = "pending"
    }
    enum Columns: String, ColumnExpression {
        case localID = "local_id"
        case operationID = "operation_id"
        case conversationID = "conversation_id"
        case pending = "pending"
    }
    /// 在调用者的基线迁移事务中创建 `direct_conversation_resolution` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("local_id", .text)
            t.column("operation_id", .text)
            t.column("conversation_id", .text)
            t.column("pending", .integer).notNull()
        }
    }
}
