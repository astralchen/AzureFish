import Foundation
import GRDB

/// `sync_checkpoint` 的类型化持久记录；字段及关联由账号基线建立。
struct CheckpointRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`sync_checkpoint`。
    static let databaseTableName = "sync_checkpoint"
    /// 检查点所属同步流的稳定名称，账号增量当前为 account_events。
    var stream: String
    /// 已持久化的增量同步游标，不从实时提示直接推进。
    var cursor: String
    /// 与游标对应的服务端同步代次。
    var epoch: String
    enum CodingKeys: String, CodingKey {
        case stream = "stream"
        case cursor = "cursor"
        case epoch = "epoch"
    }
    enum Columns: String, ColumnExpression {
        case stream = "stream"
        case cursor = "cursor"
        case epoch = "epoch"
    }
    /// 在调用者的基线迁移事务中创建 `sync_checkpoint` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("stream", .text)
            t.column("cursor", .text).notNull()
            t.column("epoch", .text).notNull()
        }
    }
}
