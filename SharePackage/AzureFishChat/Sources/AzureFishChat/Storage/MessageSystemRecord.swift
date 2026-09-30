import Foundation
import GRDB

/// `message_system_content` 的类型化持久记录；字段及关联由账号基线建立。
struct MessageSystemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message_system_content`。
    static let databaseTableName = "message_system_content"
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 服务端系统事件种类原值，未知种类原样保留。
    var kind: String
    /// 系统事件关联的联系人关系身份。
    var relationshipID: String
    /// 系统事件对应的联系人关系版本。
    var relationshipRevision: Int64
    /// 联系人申请发起者的用户身份。
    var requesterID: String
    /// 接受联系人申请的用户身份。
    var accepterID: String
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case kind = "kind"
        case relationshipID = "relationship_id"
        case relationshipRevision = "relationship_revision"
        case requesterID = "requester_id"
        case accepterID = "accepter_id"
    }
    enum Columns: String, ColumnExpression {
        case messageID = "message_id"
        case kind = "kind"
        case relationshipID = "relationship_id"
        case relationshipRevision = "relationship_revision"
        case requesterID = "requester_id"
        case accepterID = "accepter_id"
    }
    /// 在调用者的基线迁移事务中创建 `message_system_content` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("message_id", .text).references("message", column: "id", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("relationship_id", .text).notNull()
            t.column("relationship_revision", .integer).notNull()
            t.column("requester_id", .text).notNull()
            t.column("accepter_id", .text).notNull()
        }
    }
}
