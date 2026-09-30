import Foundation
import GRDB

/// `media_asset_geometry` 的类型化持久记录；字段及关联由账号基线建立。
struct AssetGeometryRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_asset_geometry`。
    static let databaseTableName = "media_asset_geometry"
    /// 由媒体资产版本与身份组合的本地关联键。
    var assetKey: String
    /// 媒体宽度，单位为像素。
    var width: Int32
    /// 媒体高度，单位为像素。
    var height: Int32
    /// 媒体时长，单位为毫秒。
    var duration: Int64
    /// 媒体是否包含动画内容。
    var animated: Bool
    enum CodingKeys: String, CodingKey {
        case assetKey = "asset_key"
        case width = "width"
        case height = "height"
        case duration = "duration"
        case animated = "animated"
    }
    enum Columns: String, ColumnExpression {
        case assetKey = "asset_key"
        case width = "width"
        case height = "height"
        case duration = "duration"
        case animated = "animated"
    }
    /// 在调用者的基线迁移事务中创建 `media_asset_geometry` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("asset_key", .text).references("media_asset", column: "key", onDelete: .cascade)
            t.column("width", .integer).notNull()
            t.column("height", .integer).notNull()
            t.column("duration", .integer).notNull()
            t.column("animated", .integer).notNull()
        }
    }
}
