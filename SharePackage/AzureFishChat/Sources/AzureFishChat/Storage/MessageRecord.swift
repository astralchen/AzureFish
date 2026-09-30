import Foundation
import GRDB

/// `message` 的类型化持久记录；字段及关联由账号基线建立。
struct MessageRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`message`。
    static let databaseTableName = "message"
    /// 贯穿本地发送和服务端确认的消息 UUID 字符串。
    var id: String
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    var clientID: String
    /// 服务端分配的消息身份。
    var serverID: String
    /// 消息发送者的用户身份。
    var senderID: String
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    var deviceID: String
    /// 消息在会话中的服务端序列，用于排序及可见边界判断。
    var sequence: Int64
    /// 服务端创建时间，采用 Unix 毫秒时间戳。
    var createdAt: Int64
    /// 此快照的版本号，用于合并时拒绝较旧状态。
    var revision: Int64
    /// 内容类型原值；与 schemaVersion 一起决定客户端是否能解释正文。
    var kind: String
    /// 消息内容的协议版本；未知版本应保留并展示兼容占位。
    var schemaVersion: Int32
    /// 消息是否已被服务端确认撤回。
    var revoked: Bool
    /// 原值是否包含格式片段集合，用于区分 nil 与空集合。
    var hasTextRuns: Bool
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case conversationID = "conversation_id"
        case clientID = "client_id"
        case serverID = "server_id"
        case senderID = "sender_id"
        case deviceID = "device_id"
        case sequence = "sequence"
        case createdAt = "created_at"
        case revision = "revision"
        case kind = "kind"
        case schemaVersion = "schema_version"
        case revoked = "revoked"
        case hasTextRuns = "has_text_runs"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case conversationID = "conversation_id"
        case clientID = "client_id"
        case serverID = "server_id"
        case senderID = "sender_id"
        case deviceID = "device_id"
        case sequence = "sequence"
        case createdAt = "created_at"
        case revision = "revision"
        case kind = "kind"
        case schemaVersion = "schema_version"
        case revoked = "revoked"
        case hasTextRuns = "has_text_runs"
    }
    /// 在调用者的基线迁移事务中创建 `message` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("conversation_id", .text).notNull()
            t.column("client_id", .text).notNull()
            t.column("server_id", .text).notNull()
            t.column("sender_id", .text).notNull()
            t.column("device_id", .text).notNull()
            t.column("sequence", .integer).notNull()
            t.column("created_at", .integer).notNull()
            t.column("revision", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("schema_version", .integer).notNull()
            t.column("revoked", .integer).notNull()
            t.column("has_text_runs", .integer).notNull()
        }
        try db.create(index: "idx_message_0", on: databaseTableName, columns: ["conversation_id", "sequence"], unique: true)
        try db.create(index: "idx_message_1", on: databaseTableName, columns: ["conversation_id", "created_at", "id"])
    }
}
