import Foundation
import GRDB

/// `message_presentation_waveform` 的类型化持久记录；字段及关联由账号基线建立。
struct PresentationWaveRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_presentation_waveform`。
    static let databaseTableName = "message_presentation_waveform"
    /// 所属派生展示缓存的消息身份，用于连接展示根记录。
    var ownerID: String
    /// 附件在父集合中从 0 开始的位置。
    var attachmentPosition: Int
    /// 同一父记录内从 0 开始的顺序位置，用于恢复原集合顺序。
    var position: Int
    /// 此位置的音频波形采样值，按 position 还原原始顺序。
    var value: Float
    enum CodingKeys: String, CodingKey {
        case ownerID = "owner_id"
        case attachmentPosition = "attachment_position"
        case position = "position"
        case value = "value"
    }
    enum Columns: String, ColumnExpression {
        case ownerID = "owner_id"
        case attachmentPosition = "attachment_position"
        case position = "position"
        case value = "value"
    }
    /// 在调用者的基线迁移事务中创建 `message_presentation_waveform` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.column("owner_id", .text).notNull().references("message_presentation_cache", column: "message_id", onDelete: .cascade)
            t.column("attachment_position", .integer).notNull()
            t.column("position", .integer).notNull()
            t.column("value", .double).notNull()
            t.primaryKey(["owner_id", "attachment_position", "position"])
        }
    }
}
