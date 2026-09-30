import Foundation
import GRDB

/// `contact_available_action` 的类型化持久记录；字段及关联由账号基线建立。
struct ContactActionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`contact_available_action`。
    static let databaseTableName = "contact_available_action"
    /// 当前账号对应的联系人用户身份。
    var peerID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 联系人操作的稳定协议值。
    var action: String
    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case position = "position"
        case action = "action"
    }
    enum Columns: String, ColumnExpression {
        case peerID = "peer_id"
        case position = "position"
        case action = "action"
    }
    /// 在调用者的基线迁移事务中创建 `contact_available_action` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("peer_id", .text).notNull().references("contact_relationship", column: "peer_id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("action", .text).notNull()
            t.primaryKey(["peer_id", "position"])
        }
    }
}
