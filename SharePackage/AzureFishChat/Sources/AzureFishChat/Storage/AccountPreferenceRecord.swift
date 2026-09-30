import Foundation
import GRDB

/// `account_local_preference` 的类型化持久记录；字段及关联由账号基线建立。
struct AccountPreferenceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`account_local_preference`。
    static let databaseTableName = "account_local_preference"
    /// 账号本机偏好记录的固定主键，当前为 1。
    var id: Int
    /// 当前账号是否折叠置顶会话区。
    var pinnedCollapsed: Bool
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case pinnedCollapsed = "pinned_collapsed"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case pinnedCollapsed = "pinned_collapsed"
    }
    /// 在调用者的基线迁移事务中创建 `account_local_preference` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .integer)
            t.column("pinned_collapsed", .integer).notNull()
        }
    }
}
