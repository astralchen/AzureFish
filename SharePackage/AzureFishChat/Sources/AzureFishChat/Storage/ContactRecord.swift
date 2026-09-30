import Foundation
import GRDB

/// `contact_relationship` 的类型化持久记录；字段及关联由账号基线建立。
struct ContactRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`contact_relationship`。
    static let databaseTableName = "contact_relationship"
    /// 当前账号对应的联系人用户身份。
    var peerID: String
    /// 当前联系人关系的稳定身份。
    var id: String
    /// 联系人关系状态原值；新语义使用 isContact、isBlocked 及 availableActions 判定操作。
    var state: String
    /// 联系人申请发起者的用户身份。
    var requesterID: String
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    var revision: Int64
    /// 服务端更新时间，采用 Unix 毫秒时间戳。
    var updatedAt: Int64
    /// 联系人语义版本；版本 2 才解释显式操作权限。
    var semanticsVersion: Int32
    /// 对方是否在当前账号的联系人列表中。
    var isContact: Bool
    /// 当前账号为联系人设置的备注；空字符串表示未设置。
    var remark: String
    /// 当前账号是否已拉黑对方。
    var isBlocked: Bool
    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case id = "id"
        case state = "state"
        case requesterID = "requester_id"
        case revision = "revision"
        case updatedAt = "updated_at"
        case semanticsVersion = "semantics_version"
        case isContact = "is_contact"
        case remark = "remark"
        case isBlocked = "is_blocked"
    }
    enum Columns: String, ColumnExpression {
        case peerID = "peer_id"
        case id = "id"
        case state = "state"
        case requesterID = "requester_id"
        case revision = "revision"
        case updatedAt = "updated_at"
        case semanticsVersion = "semantics_version"
        case isContact = "is_contact"
        case remark = "remark"
        case isBlocked = "is_blocked"
    }
    /// 在调用者的基线迁移事务中创建 `contact_relationship` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("peer_id", .text).references("user_profile", column: "id", onDelete: .cascade)
            t.column("id", .text).notNull()
            t.column("state", .text).notNull()
            t.column("requester_id", .text).notNull()
            t.column("revision", .integer).notNull()
            t.column("updated_at", .integer).notNull()
            t.column("semantics_version", .integer).notNull()
            t.column("is_contact", .integer).notNull()
            t.column("remark", .text).notNull()
            t.column("is_blocked", .integer).notNull()
        }
    }
}
