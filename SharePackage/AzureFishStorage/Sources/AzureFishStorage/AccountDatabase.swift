import Foundation
import GRDB

/// 账号存储打开或生命周期校验失败；不会触发自动清理或密钥替换。
public enum AccountStorageError: Error, Sendable, Equatable {
    case invalidKey, scopeMismatch, incompatibleSchema, unavailable, invalidMigration
}

/// 单一迁移账本中的有序步骤；已交付的标识和实现不得改写。
public struct AccountMigration: Sendable {
    /// 迁移的非空唯一标识；必须与既有迁移账本及顺序兼容。
    public let identifier: String
    /// 在 GRDB 迁移事务中同步执行的步骤；连接不得逃逸，失败抛错触发回滚。
    let migrate: @Sendable (Database) throws -> Void

    /// 保存迁移身份和实现；重复或空标识在 AccountDatabase 打开时校验。
    public init(_ identifier: String, migrate: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier
        self.migrate = migrate
    }
}

private struct AccountIdentity: Codable, FetchableRecord, PersistableRecord {
    /// 保存环境与账号归属的单行身份表名称。
    static let databaseTableName = "account_store_identity"
    /// 身份记录的固定主键，当前为 1。
    var id: Int
    /// 数据库所属服务环境的稳定标识。
    var environment: String
    /// 数据库所属用户的 UUID 小写字符串。
    var userID: String
    enum CodingKeys: String, CodingKey { case id, environment; case userID = "user_id" }
}

/// 持有一个环境、账号的加密数据库；由账号协调器创建、注入及最终关闭。
///
/// 同步闭包在 GRDB 调度环境执行，不能挂起或让连接逃逸。业务模块只能结束自身访问，
/// 不应关闭其他模块共享的实例。锁使最终关闭与新读写互斥，GRDB 负责事务回滚。
public final class AccountDatabase: @unchecked Sendable {
    /// 此数据库所属的服务环境标识，打开旧库时必须匹配。
    public let environment: String
    /// 此数据库所属账号的用户身份，打开旧库时必须匹配。
    public let userID: UUID
    /// 持有 SQLCipher 连接并负责读写事务的 GRDB 队列。
    private let queue: DatabaseQueue
    /// 协调关闭、资源引用检查及业务读写的递归锁。
    private let lock = NSRecursiveLock()
    /// 数据库是否已成功关闭，初始为 false；关闭后拒绝新业务访问。
    private var closed = false
    /// 按业务域登记的资源引用查询；同一域再次注册时替换原闭包。
    private var resourceReferences: [String: @Sendable (Database, UUID) throws -> Bool] = [:]

    /// 校验密钥长度及账号归属，打开加密数据库并按顺序执行尚未应用的迁移。
    ///
    /// 旧库先只读验证身份和迁移前缀；失败不自动替换密钥或重建数据库。
    ///
    /// - Parameters:
    ///   - url: 数据库文件地址；父目录及其保护策略由调用方准备。
    ///   - key: 恰好 32 字节的随机数据库密钥。
    ///   - environment: 与旧库身份匹配的环境标识。
    ///   - userID: 与旧库身份匹配的账号身份。
    ///   - baseline: 首次建立基线时执行的同步建表闭包，不能挂起或让连接逃逸。
    ///   - migrations: 基线之后按数组顺序应用的迁移，默认空；标识必须非空且唯一。
    /// - Throws: 密钥长度、身份、版本或迁移标识错误，以及 GRDB 打开、解密或迁移错误。
    public init(url: URL, key: Data, environment: String, userID: UUID,
                baseline: @escaping @Sendable (Database) throws -> Void,
                migrations: [AccountMigration] = []) throws {
        guard key.count == 32 else { throw AccountStorageError.invalidKey }
        let identifiers = ["account-storage-v1"] + migrations.map(\.identifier)
        guard Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ !$0.isEmpty }) else { throw AccountStorageError.invalidMigration }
        self.environment = environment
        self.userID = userID
        let identity = userID.uuidString.lowercased()
        let existed = FileManager.default.fileExists(atPath: url.path)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { try $0.usePassphrase(key.base64EncodedString()) }
        // 先以只读连接检查旧库，版本不兼容时不运行迁移或写入身份。
        if existed {
            var readOnly = configuration
            readOnly.readonly = true
            let probe = try DatabaseQueue(path: url.path, configuration: readOnly)
            defer { try? probe.close() }
            try probe.read { db in
                guard try db.tableExists(AccountIdentity.databaseTableName),
                      try db.tableExists("grdb_migrations") else { throw AccountStorageError.incompatibleSchema }
                guard let saved = try AccountIdentity.fetchOne(db, key: 1),
                      saved.environment == environment, saved.userID == identity else { throw AccountStorageError.scopeMismatch }
                let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                guard !applied.isEmpty, applied == Array(identifiers.prefix(applied.count)) else {
                    throw AccountStorageError.incompatibleSchema
                }
            }
        }
        queue = try DatabaseQueue(path: url.path, configuration: configuration)
        do {
            try queue.read { db in
                guard try String.fetchOne(db, sql: "PRAGMA cipher_version")?.isEmpty == false else {
                    throw AccountStorageError.invalidKey
                }
            }
            var migrator = DatabaseMigrator()
            migrator.registerMigration("account-storage-v1") { db in
                try db.create(table: AccountIdentity.databaseTableName) { t in
                    t.primaryKey("id", .integer)
                    t.column("environment", .text).notNull()
                    t.column("user_id", .text).notNull()
                }
                try baseline(db)
                try AccountIdentity(id: 1, environment: environment, userID: identity).insert(db)
            }
            for migration in migrations { migrator.registerMigration(migration.identifier, migrate: migration.migrate) }
            try migrator.migrate(queue)
        } catch {
            try? queue.close()
            throw error
        }
    }

    /// 在同一读取快照中执行同步闭包并返回结果。
    ///
    /// - Parameter body: 同步读取操作；连接不得逃逸，不能在闭包内挂起。
    /// - Throws: 关闭后的 unavailable，或 GRDB 与闭包原样抛出的错误。
    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw AccountStorageError.unavailable }
        return try queue.read(body)
    }

    /// 原子提交闭包内的数据库写入；任一步抛错则回滚数据库事务。
    ///
    /// - Parameter body: 同步写入操作；连接不得逃逸，文件或网络等外部副作用不会随事务自动回滚。
    /// - Returns: 闭包成功产生的结果。
    /// - Throws: 关闭后的 unavailable，或 GRDB 与闭包原样抛出的错误。
    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw AccountStorageError.unavailable }
        return try queue.write(body)
    }

    /// 在账号打开时注册所有已安装业务的资源引用查询，包括当前没有页面的业务。
    /// 查询必须使用传入事务；已有数据的业务不能等到首次写入时才注册。
    /// 同一 domain 再次注册会替换旧查询；本实例持有闭包直到自身释放。
    ///
    /// - Parameters:
    ///   - domain: 已安装业务域的稳定唯一名称。
    ///   - contains: 在给定数据库事务内判断资源是否仍被引用的同步闭包。
    /// - Throws: 数据库已关闭时抛出 unavailable。
    public func registerResourceReferences(domain: String, contains: @escaping @Sendable (Database, UUID) throws -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw AccountStorageError.unavailable }
        resourceReferences[domain] = contains
    }

    /// 在同一数据库写入排他区间内检查全部业务引用并删除文件，阻止检查与删除之间插入新引用。
    /// 文件删除失败会抛错；调用者保留清理请求以便重试。
    ///
    /// - Parameters:
    ///   - id: 待清理资源的稳定身份。
    ///   - removal: 全部已注册业务均无引用时同步执行一次的删除操作；必须在返回前完成。
    /// - Returns: 已执行 removal 时为 true；任一业务仍有引用时为 false。
    /// - Throws: 已关闭或尚未注册任何引用查询时为 unavailable，其他查询及删除错误原样抛出。
    public func removeResourceIfUnreferenced(_ id: UUID, removal: () throws -> Void) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !resourceReferences.isEmpty else { throw AccountStorageError.unavailable }
        let references = Array(resourceReferences.values)
        return try queue.write { db in
            for contains in references where try contains(db, id) { return false }
            try removal()
            return true
        }
    }

    /// 在所有业务任务停止后由账号所有者调用；重复关闭无副作用。
    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try queue.close()
        closed = true
    }
}
