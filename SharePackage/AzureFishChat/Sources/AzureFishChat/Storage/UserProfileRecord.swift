import Foundation
import GRDB

/// `user_profile` 的类型化持久记录；字段及关联由账号基线建立。
struct UserProfileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// 此持久记录对应的数据库表名：`user_profile`。
    static let databaseTableName = "user_profile"
    /// 用户的稳定身份。
    var id: String
    /// 用户公开昵称，保留原始文本。
    var nickname: String
    /// 公开资料版本，用于独立于关系版本合并昵称及头像。
    var version: Int64
    /// 头像资源身份；nil 表示没有指定头像。
    var avatarID: String?
    /// 用户删除状态；nil 表示旧快照未提供该字段。
    var deleted: Bool?
    enum CodingKeys: String, CodingKey {
        case id = "id"
        case nickname = "nickname"
        case version = "version"
        case avatarID = "avatar_id"
        case deleted = "deleted"
    }
    enum Columns: String, ColumnExpression {
        case id = "id"
        case nickname = "nickname"
        case version = "version"
        case avatarID = "avatar_id"
        case deleted = "deleted"
    }
    /// 在调用者的基线迁移事务中创建 `user_profile` 表及声明的约束、索引；失败向上抛出，不自行开启事务。
    static func create(in db: Database) throws {
        try db.create(table: databaseTableName) { t in
            t.primaryKey("id", .text)
            t.column("nickname", .text).notNull()
            t.column("version", .integer).notNull()
            t.column("avatar_id", .text)
            t.column("deleted", .integer)
        }
    }
}
