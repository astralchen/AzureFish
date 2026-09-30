import Foundation
import GRDB

/// `contact_pending_operation` 的类型化持久记录；字段及关联由账号基线建立。
struct ContactOperationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`contact_pending_operation`。
    static let databaseTableName = "contact_pending_operation"
    /// 当前账号对应的联系人用户身份。
    var peerID: String
    /// 未决联系人请求的原始 Protobuf 字节，恢复时必须逐字节复用。
    var bytes: Data
    /// 联系人操作的稳定协议值。
    var action: String
    /// 当前账号为联系人设置的备注；空字符串表示未设置。
    var remark: String
    /// 联系人申请随附的原始文字。
    var message: String
    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case bytes = "bytes"
        case action = "action"
        case remark = "remark"
        case message = "message"
    }
    enum Columns: String, ColumnExpression {
        case peerID = "peer_id"
        case bytes = "bytes"
        case action = "action"
        case remark = "remark"
        case message = "message"
    }
    /// 在调用者的基线迁移事务中创建 `contact_pending_operation` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("peer_id", .text)
            t.column("bytes", .blob).notNull()
            t.column("action", .text).notNull()
            t.column("remark", .text).notNull()
            t.column("message", .text).notNull()
        }
    }
}
