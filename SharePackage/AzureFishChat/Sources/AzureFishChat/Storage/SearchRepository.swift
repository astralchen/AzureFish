import AzureFishAPI
import GRDB

struct SearchRecord: Codable, FetchableRecord, PersistableRecord {
    /// 此持久记录对应的数据库表名：`message_search`。
    static let databaseTableName = "message_search"
    /// 索引对应的权威消息身份。
    var id: String
    /// 由安全分词器生成、以空格连接的 FTS token，不是用户原始正文。
    var body: String
    enum Columns: String, ColumnExpression { case id, body }
}
/// FTS 只保存搜索 token，权威正文、权限和分页字段由类型化消息查询提供。
enum SearchRepository {
    /// 从 FTS 表删除指定消息的所有索引行，不删除权威消息正文。
    static func remove(_ id: String, in db: Database) throws {
        try SearchRecord.filter(SearchRecord.Columns.id == id).deleteAll(db)
    }
    /// 将消息文字分词后插入 FTS 索引；调用方负责先移除旧索引并确认消息允许搜索。
    static func index(_ value: ChatMessage, in db: Database) throws {
        try SearchRecord(id: value.id, body: ChatSearchTokenizer.tokens(value.text).joined(separator: " ")).insert(db)
    }
}
