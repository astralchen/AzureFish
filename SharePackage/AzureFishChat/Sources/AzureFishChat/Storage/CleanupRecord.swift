import Foundation
import GRDB

/// `media_cleanup_request` 的类型化持久记录；字段及关联由账号基线建立。
struct CleanupRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_cleanup_request`。
    static let databaseTableName = "media_cleanup_request"
    /// 所关联加密媒体资源的稳定身份。
    var resourceID: String
    enum CodingKeys: String, CodingKey {
        case resourceID = "resource_id"
    }
    enum Columns: String, ColumnExpression {
        case resourceID = "resource_id"
    }
    /// 在调用者的基线迁移事务中创建 `media_cleanup_request` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("resource_id", .text)
        }
    }
}
