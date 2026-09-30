import Foundation
import GRDB

/// `message_send_task_attachment` 的类型化持久记录；字段及关联由账号基线建立。
struct SendAssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_send_task_attachment`。
    static let databaseTableName = "message_send_task_attachment"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 服务端媒体资产身份。
    var assetID: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case position = "position"
        case assetID = "asset_id"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case position = "position"
        case assetID = "asset_id"
    }
    /// 在调用者的基线迁移事务中创建 `message_send_task_attachment` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("message_id", .text).notNull().references("message_send_task", column: "id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("asset_id", .text).notNull()
            t.primaryKey(["message_id", "position"])
        }
    }
}
