import Foundation
import GRDB

/// `media_asset_resource` 的类型化持久记录；字段及关联由账号基线建立。
struct AssetResourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_asset_resource`。
    static let databaseTableName = "media_asset_resource"
    /// 由媒体资产版本与身份组合的本地关联键。
    var assetKey: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 所关联加密媒体资源的稳定身份。
    var resourceID: String
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    var role: String
    enum CodingKeys: String, CodingKey {
        case assetKey = "asset_key"
        case position = "position"
        case resourceID = "resource_id"
        case role = "role"
    }
    enum Columns: String, ColumnExpression {
        case assetKey = "asset_key"
        case position = "position"
        case resourceID = "resource_id"
        case role = "role"
    }
    /// 在调用者的基线迁移事务中创建 `media_asset_resource` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("asset_key", .text).notNull().references("media_asset", column: "key", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("resource_id", .text).notNull().references("media_resource", column: "id")
            t.column("role", .text).notNull()
            t.primaryKey(["asset_key", "position"])
        }
    }
}
