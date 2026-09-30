import Foundation
import GRDB

/// `media_asset` 的类型化持久记录；字段及关联由账号基线建立。
struct AssetRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_asset`。
    static let databaseTableName = "media_asset"
    /// 由元数据版本及资产身份组合的主键，格式为版本:身份。
    var key: String
    /// 服务端媒体资产的稳定身份。
    var id: String
    /// 媒体资产种类原值，例如 image、video、audio 或 file。
    var kind: String
    /// 媒体元数据版本，与资产身份共同构成本地存储键。
    var version: Int64
    enum CodingKeys: String, CodingKey {
        case key = "key"
        case id = "id"
        case kind = "kind"
        case version = "version"
    }
    enum Columns: String, ColumnExpression {
        case key = "key"
        case id = "id"
        case kind = "kind"
        case version = "version"
    }
    /// 在调用者的基线迁移事务中创建 `media_asset` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("key", .text)
            t.column("id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("version", .integer).notNull()
        }
    }
}
