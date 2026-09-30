import Foundation
import GRDB

/// `media_upload_batch` 的类型化持久记录；字段及关联由账号基线建立。
struct UploadBatchRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_upload_batch`。
    static let databaseTableName = "media_upload_batch"
    /// 本机上传批次的稳定 UUID 字符串。
    var id: String
    /// 所关联消息的稳定身份。
    var messageID: String
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    var clientID: String
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    var operationID: String
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    var deviceID: String
    /// 批次本机创建时间，采用 Unix 秒时间戳。
    var createdAt: Double
    /// 所属聊天会话的稳定身份。
    var conversationID: String
    /// 上传完成后发送的消息内容类型。
    var kind: String
    /// 上传或终止状态原值；removed 与 submitted 记录用于拒绝迟到更新。
    var state: String
    /// 已记录完成的上传字节数。
    var completedBytes: Int64
    /// 是否已请求取消上传；迟到进度不能将其恢复为 false。
    var cancelRequested: Bool
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case messageID = "message_id"
        case clientID = "client_id"
        case operationID = "operation_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
        case conversationID = "conversation_id"
        case kind = "kind"
        case state = "state"
        case completedBytes = "completed_bytes"
        case cancelRequested = "cancel_requested"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case messageID = "message_id"
        case clientID = "client_id"
        case operationID = "operation_id"
        case deviceID = "device_id"
        case createdAt = "created_at"
        case conversationID = "conversation_id"
        case kind = "kind"
        case state = "state"
        case completedBytes = "completed_bytes"
        case cancelRequested = "cancel_requested"
    }
    /// 在调用者的基线迁移事务中创建 `media_upload_batch` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("message_id", .text).notNull()
            t.column("client_id", .text).notNull()
            t.column("operation_id", .text).notNull()
            t.column("device_id", .text).notNull()
            t.column("created_at", .double).notNull()
            t.column("conversation_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("state", .text).notNull()
            t.column("completed_bytes", .integer).notNull()
            t.column("cancel_requested", .integer).notNull()
        }
    }
}
