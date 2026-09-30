import Foundation
import GRDB

/// `contact_request` 的类型化持久记录；字段及关联由账号基线建立。
struct ContactRequestRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`contact_request`。
    static let databaseTableName = "contact_request"
    /// 当前账号对应的联系人用户身份。
    var peerID: String
    /// 联系人申请身份，空字符串表示没有对应申请。
    var requestID: String
    /// 联系人申请的服务端状态原值。
    var state: String
    /// 联系人申请随附的原始文字。
    var message: String
    /// 服务端更新时间，采用 Unix 毫秒时间戳。
    var updatedAt: Int64
    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case requestID = "request_id"
        case state = "state"
        case message = "message"
        case updatedAt = "updated_at"
    }
    enum Columns: String, ColumnExpression {
        case peerID = "peer_id"
        case requestID = "request_id"
        case state = "state"
        case message = "message"
        case updatedAt = "updated_at"
    }
    /// 在调用者的基线迁移事务中创建 `contact_request` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("peer_id", .text).references("contact_relationship", column: "peer_id", onDelete: .cascade)
            t.column("request_id", .text).notNull()
            t.column("state", .text).notNull()
            t.column("message", .text).notNull()
            t.column("updated_at", .integer).notNull()
        }
    }
}
