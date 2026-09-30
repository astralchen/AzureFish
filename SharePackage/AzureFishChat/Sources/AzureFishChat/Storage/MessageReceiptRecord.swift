import Foundation
import GRDB

/// `message_receipt_summary` 的类型化持久记录；字段及关联由账号基线建立。
struct MessageReceiptRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_receipt_summary`。
    static let databaseTableName = "message_receipt_summary"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 此消息预期收到回执的成员数量。
    var expected: Int64
    /// 此消息已确认送达的成员数量。
    var delivered: Int64
    /// 此消息已确认已读的成员数量。
    var read: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    var revision: Int64
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case expected = "expected"
        case delivered = "delivered"
        case read = "read"
        case revision = "revision"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case expected = "expected"
        case delivered = "delivered"
        case read = "read"
        case revision = "revision"
    }
    /// 在调用者的基线迁移事务中创建 `message_receipt_summary` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text).references("message", column: "id", onDelete: .cascade)
            t.column("expected", .integer).notNull()
            t.column("delivered", .integer).notNull()
            t.column("read", .integer).notNull()
            t.column("revision", .integer).notNull()
        }
    }
}
