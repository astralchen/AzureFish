import Foundation
import GRDB

/// `media_resource` 的类型化持久记录；字段及关联由账号基线建立。
struct ResourceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`media_resource`。
    static let databaseTableName = "media_resource"
    /// 资源的稳定身份；同一身份不允许改写长度和摘要。
    var id: String
    /// 资源文件名，仅为元数据，不是本地文件路径。
    var filename: String
    /// 资源的 MIME 类型字符串。
    var mime: String
    /// 资源完整长度，单位为字节。
    var bytes: Int64
    /// 完整资源内容的 SHA-256 十六进制摘要。
    var sha256: String
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case filename = "filename"
        case mime = "mime"
        case bytes = "bytes"
        case sha256 = "sha256"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case filename = "filename"
        case mime = "mime"
        case bytes = "bytes"
        case sha256 = "sha256"
    }
    /// 在调用者的基线迁移事务中创建 `media_resource` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("filename", .text).notNull()
            t.column("mime", .text).notNull()
            t.column("bytes", .integer).notNull()
            t.column("sha256", .text).notNull()
        }
    }
}
