import Foundation
import GRDB

/// `message_presentation_attachment` 的类型化持久记录；字段及关联由账号基线建立。
struct PresentationAttachmentRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_attachment`。
    static let databaseTableName = "message_presentation_attachment"
    /// 所属派生展示缓存的消息身份，用于连接展示根记录。
    var ownerID: String
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 附件所属编辑器槽位，区分 document、media 和 audio。
    var slot: String
    /// 编辑器附件的稳定 UUID 字符串。
    var id: String
    /// 附件种类原值，支持 audio、mediaGroup、file 和 link。
    var kind: String
    /// 文件或语音的加密资源身份；不适用的附件种类为 nil。
    var resourceID: String?
    /// 文件缩略图或链接封面资源身份；没有预览资源时为 nil。
    var thumbnailID: String?
    /// 链接图标在加密存储中的资源身份；nil 表示未缓存图标。
    var iconID: String?
    /// 文件附件的展示名称；不适用的附件种类为 nil。
    var filename: String?
    /// 文件附件的统一类型标识符；其他附件种类可为 nil。
    var typeIdentifier: String?
    /// 文件附件字节数；其他附件种类可为 nil。
    var byteCount: Int64?
    /// 链接附件的 URL 原文；其他种类或未提供时为 nil。
    var url: String?
    /// 链接附件的可选标题；nil 表示没有标题。
    var title: String?
    /// 语音附件时长，单位为秒；其他附件可为 nil。
    var duration: Double?
    /// 音频转写文字；nil 表示没有已保存的转写。
    var transcript: String?
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case position = "position"
        case slot = "slot"
        case id = "id"
        case kind = "kind"
        case resourceID = "resource_id"
        case thumbnailID = "thumbnail_id"
        case iconID = "icon_id"
        case filename = "filename"
        case typeIdentifier = "type_identifier"
        case byteCount = "byte_count"
        case url = "url"
        case title = "title"
        case duration = "duration"
        case transcript = "transcript"
    }
    enum Columns: String, ColumnExpression {
        case ownerID = "owner_id"
        case position = "position"
        case slot = "slot"
        case id = "id"
        case kind = "kind"
        case resourceID = "resource_id"
        case thumbnailID = "thumbnail_id"
        case iconID = "icon_id"
        case filename = "filename"
        case typeIdentifier = "type_identifier"
        case byteCount = "byte_count"
        case url = "url"
        case title = "title"
        case duration = "duration"
        case transcript = "transcript"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_attachment` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("owner_id", .text).notNull().references("message_presentation_cache", column: "message_id", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("slot", .text).notNull()
            t.column("id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("resource_id", .text)
            t.column("thumbnail_id", .text)
            t.column("icon_id", .text)
            t.column("filename", .text)
            t.column("type_identifier", .text)
            t.column("byte_count", .integer)
            t.column("url", .text)
            t.column("title", .text)
            t.column("duration", .double)
            t.column("transcript", .text)
            t.primaryKey(["owner_id", "position"])
        }
    }
}
