import Foundation
import GRDB

/// `message_presentation_resource` 的类型化持久记录；字段及关联由账号基线建立。
struct RetiredResourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_resource`。
    static let databaseTableName = "message_presentation_resource"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 所关联加密媒体资源的稳定身份。
    var resourceID: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case resourceID = "resource_id"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case resourceID = "resource_id"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_resource` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("message_id", .text).notNull()
            t.column("resource_id", .text).notNull()
            t.primaryKey(["message_id", "resource_id"])
        }
    }
}
