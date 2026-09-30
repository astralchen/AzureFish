import Foundation
import GRDB

/// `message_presentation_segment_run` 的类型化持久记录；字段及关联由账号基线建立。
struct PresentationSegmentRunRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_segment_run`。
    static let databaseTableName = "message_presentation_segment_run"
    /// 所属派生展示缓存的消息身份，用于连接展示根记录。
    var ownerID: String
    /// 编辑片段在父集合中从 0 开始的位置。
    var segmentPosition: Int
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 原始文字内容；空字符串表示没有文字，不在存储层本地化。
    var text: String
    /// 语义格式位掩码；低四位依次表示粗体、斜体、下划线和删除线。
    var style: UInt32
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case segmentPosition = "segment_position"
        case position = "position"
        case text = "text"
        case style = "style"
    }
    enum Columns: String, ColumnExpression {
        case ownerID = "owner_id"
        case segmentPosition = "segment_position"
        case position = "position"
        case text = "text"
        case style = "style"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_segment_run` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("owner_id", .text).notNull().references("message_presentation_cache", column: "message_id", onDelete: .cascade)
            t.column("segment_position", .integer).notNull()
            t.column("position", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("style", .integer).notNull()
            t.primaryKey(["owner_id", "segment_position", "position"])
        }
    }
}
