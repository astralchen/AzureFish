import Foundation
import GRDB

/// `message_presentation_media_item` 的类型化持久记录；字段及关联由账号基线建立。
struct PresentationMediaItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_media_item`。
    static let databaseTableName = "message_presentation_media_item"
    /// 所属派生展示缓存的消息身份，用于连接展示根记录。
    var ownerID: String
    /// 附件在父集合中从 0 开始的位置。
    var attachmentPosition: Int
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 媒体组内条目的稳定 UUID 字符串。
    var id: String
    /// 系统相册资产标识；nil 表示来源没有提供此标识。
    var assetIdentifier: String?
    /// 媒体原始文件在加密存储中的资源身份。
    var originalID: String
    /// 缩略图在加密存储中的资源身份。
    var thumbnailID: String
    /// Live Photo 配对视频的资源身份；nil 表示没有配对视频。
    var pairedVideoID: String?
    /// 媒体宽度，单位为像素。
    var width: Double
    /// 媒体高度，单位为像素。
    var height: Double
    /// 视频时长，单位为秒；nil 表示图片条目。
    var duration: Double?
    /// 媒体是否包含动画内容。
    var animated: Bool
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case attachmentPosition = "attachment_position"
        case position = "position"
        case id = "id"
        case assetIdentifier = "asset_identifier"
        case originalID = "original_id"
        case thumbnailID = "thumbnail_id"
        case pairedVideoID = "paired_video_id"
        case width = "width"
        case height = "height"
        case duration = "duration"
        case animated = "animated"
    }
    enum Columns: String, ColumnExpression {
        case ownerID = "owner_id"
        case attachmentPosition = "attachment_position"
        case position = "position"
        case id = "id"
        case assetIdentifier = "asset_identifier"
        case originalID = "original_id"
        case thumbnailID = "thumbnail_id"
        case pairedVideoID = "paired_video_id"
        case width = "width"
        case height = "height"
        case duration = "duration"
        case animated = "animated"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_media_item` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("owner_id", .text).notNull().references("message_presentation_cache", column: "message_id", onDelete: .cascade)
            t.column("attachment_position", .integer).notNull()
            t.column("position", .integer).notNull()
            t.column("id", .text).notNull()
            t.column("asset_identifier", .text)
            t.column("original_id", .text).notNull()
            t.column("thumbnail_id", .text).notNull()
            t.column("paired_video_id", .text)
            t.column("width", .double).notNull()
            t.column("height", .double).notNull()
            t.column("duration", .double)
            t.column("animated", .integer).notNull()
            t.primaryKey(["owner_id", "attachment_position", "position"])
        }
    }
}
