import Foundation
import GRDB

/// `conversation` 的类型化持久记录；字段及关联由账号基线建立。
struct ConversationRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`conversation`。
    static let databaseTableName = "conversation"
    /// 聊天会话的稳定身份。
    var id: String
    /// 服务端会话种类原值，例如 direct 或 group。
    var kind: String
    /// 服务端会话标题，保留原始文字。
    var title: String
    /// 群所有者的用户身份；不适用时保留服务端空值。
    var ownerID: String
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    var revision: Int64
    /// 成员消息可见边界的服务端版本。
    var boundaryRevision: Int64
    /// 会话已知的最新服务端消息序列。
    var latest: Int64
    /// 会话是否已关闭。
    var closed: Bool
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case kind = "kind"
        case title = "title"
        case ownerID = "owner_id"
        case revision = "revision"
        case boundaryRevision = "boundary_revision"
        case latest = "latest"
        case closed = "closed"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case kind = "kind"
        case title = "title"
        case ownerID = "owner_id"
        case revision = "revision"
        case boundaryRevision = "boundary_revision"
        case latest = "latest"
        case closed = "closed"
    }
    /// 在调用者的基线迁移事务中创建 `conversation` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("kind", .text).notNull()
            t.column("title", .text).notNull()
            t.column("owner_id", .text).notNull()
            t.column("revision", .integer).notNull()
            t.column("boundary_revision", .integer).notNull()
            t.column("latest", .integer).notNull()
            t.column("closed", .integer).notNull()
        }
    }
}
