import Foundation
import GRDB
import Testing
@testable import AzureFishStorage

@Suite("账号基础存储")
struct AccountDatabaseTests {
    /// 创建唯一临时测试目录；调用方负责在测试结束时清理。
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    /// 使用固定虚构密钥和 fixture 基线打开账号测试库，并应用给定迁移。
    private func open(_ url: URL, user: UUID, migrations: [AccountMigration] = []) throws -> AccountDatabase {
        try AccountDatabase(url: url, key: Data(repeating: 31, count: 32), environment: "fixture", userID: user,
            baseline: { db in try db.create(table: "fixture") { $0.primaryKey("id", .integer); $0.column("text", .text) } }, migrations: migrations)
    }
    /// 验证账号基线、有序迁移及重开账本保持一致。
    @Test func baselineOrderedMigrationsAndReopen() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db"), user = UUID()
        let original = try open(url, user: user)
        try original.write { try $0.execute(sql: "INSERT INTO fixture VALUES (1, ?)", arguments: ["private fixture"]) }
        try original.close()
        let addition = AccountMigration("chat-v2-fixture") { db in try db.create(table: "extra") { $0.primaryKey("id", .integer) } }
        let upgraded = try open(url, user: user, migrations: [addition])
        #expect(try upgraded.read { try $0.tableExists("extra") })
        #expect(try upgraded.read { try String.fetchOne($0, sql: "SELECT text FROM fixture") } == "private fixture")
        try upgraded.close()
        #expect(throws: AccountStorageError.incompatibleSchema) { _ = try open(url, user: user) }
        let reopened = try open(url, user: user, migrations: [addition]); try reopened.close()
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("private fixture"))
    }
    /// 验证旧版或未知基线被拒绝且原数据不被修改。
    @Test func oldAndUnknownBaselinesRemainUntouched() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 31, count: 32), user = UUID()
        for identifier in ["chat-v1", "future-account-v99"] {
            let url = root.appendingPathComponent(identifier)
            var configuration = Configuration(); configuration.prepareDatabase { try $0.usePassphrase(key.base64EncodedString()) }
            let old = try DatabaseQueue(path: url.path, configuration: configuration)
            var migrator = DatabaseMigrator()
            migrator.registerMigration(identifier) { db in
                try db.execute(sql: "CREATE TABLE preserved (value TEXT NOT NULL)")
                try db.execute(sql: "INSERT INTO preserved VALUES (?)", arguments: ["keep original"])
            }
            try migrator.migrate(old); try old.close()
            let before = try Data(contentsOf: url)
            #expect(throws: AccountStorageError.incompatibleSchema) { _ = try open(url, user: user) }
            #expect(try Data(contentsOf: url) == before)
            let recovery = try DatabaseQueue(path: url.path, configuration: configuration)
            #expect(try recovery.read { try String.fetchOne($0, sql: "SELECT value FROM preserved") } == "keep original")
            try recovery.close()
        }
    }
    /// 验证缺失或错误密钥、账号作用域不符时不替换原数据。
    @Test func missingWrongKeysAndScopeDoNotReplaceData() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("db"), user = UUID()
        let original = try open(url, user: user); try original.close()
        let before = try Data(contentsOf: url)
        for key in [Data(), Data(repeating: 0, count: 32)] {
            #expect(throws: (any Error).self) {
                _ = try AccountDatabase(url: url, key: key, environment: "fixture", userID: user, baseline: { _ in })
            }
        }
        #expect(throws: AccountStorageError.scopeMismatch) { _ = try open(url, user: UUID()) }
        #expect(try Data(contentsOf: url) == before)
        let reopened = try open(url, user: user); try reopened.close()
    }
    /// 验证写事务失败回滚且关闭后拒绝访问。
    @Test func transactionRollbackAndClosedAccess() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try open(root.appendingPathComponent("db"), user: UUID())
        #expect(throws: AccountStorageError.unavailable) {
            try database.write { db in
                try db.execute(sql: "INSERT INTO fixture VALUES (1, 'rollback')")
                throw AccountStorageError.unavailable
            }
        }
        #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM fixture") } == 0)
        try database.close(); try database.close()
        #expect(throws: AccountStorageError.unavailable) { try database.read { _ in () } }
    }
    /// 验证所有注册业务域释放引用后才允许资源删除。
    @Test func everyRegisteredDomainMustReleaseResource() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let database = try open(root.appendingPathComponent("db"), user: UUID()), id = UUID()
        try database.registerResourceReferences(domain: "chat") { _, _ in false }
        try database.registerResourceReferences(domain: "fixture-feature") { _, resource in resource == id }
        #expect(try database.removeResourceIfUnreferenced(id) { Issue.record("仍被其他业务引用") } == false)
        try database.registerResourceReferences(domain: "fixture-feature") { _, _ in false }
        #expect(throws: AccountStorageError.unavailable) {
            try database.removeResourceIfUnreferenced(id) { throw AccountStorageError.unavailable }
        }
        #expect(try database.removeResourceIfUnreferenced(id) {})
        try database.close()
    }
    @Test func leaseCleanupIsRepeatableAndDoesNotRecreateRemovedAccount() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EncryptedMediaStore(root: root, key: Data(repeating: 45, count: 32), environment: "cleanup", userID: UUID())
        let lease = try await store.temporaryFile(filename: "fixture.bin")
        try Data([1, 2, 3]).write(to: lease)
        try await store.clearLeases()
        #expect(!FileManager.default.fileExists(atPath: lease.path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("leases"))
        try await store.clearLeases()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("leases").path))
        try FileManager.default.removeItem(at: root)
        try await store.clearLeases()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

}
