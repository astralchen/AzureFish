import Foundation
import GRDB

/// `message_local_state` 的类型化持久记录；字段及关联由账号基线建立。
struct HiddenRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_local_state`。
    static let databaseTableName = "message_local_state"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 消息是否在本机隐藏，不等于服务端撤回。
    var hidden: Bool
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case hidden = "hidden"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case hidden = "hidden"
    }
    /// 在调用者的基线迁移事务中创建 `message_local_state` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text)
            t.column("hidden", .integer).notNull()
        }
    }
}
