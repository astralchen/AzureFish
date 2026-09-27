import Foundation
import GRDB
import Testing

@Test func sqlCipherMigrationFTSBackupAndWrongKey() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("probe.sqlite").path
    let passphrase = UUID().uuidString + UUID().uuidString
    var configuration = Configuration()
    configuration.prepareDatabase { db in try db.usePassphrase(passphrase) }
    let database = try DatabaseQueue(path: path, configuration: configuration)
    try database.read { db in
        let version = try String.fetchOne(db, sql: "PRAGMA cipher_version")
        #expect(version?.isEmpty == false)
    }
    var migrations = DatabaseMigrator()
    migrations.registerMigration("profile") { db in
        try db.execute(sql: "CREATE TABLE profile (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
        try db.execute(sql: "CREATE VIRTUAL TABLE search USING fts5(body)")
        try db.execute(sql: "INSERT INTO profile VALUES (1, 'fictional sensitive content')")
        try db.execute(sql: "INSERT INTO search VALUES ('fictional sensitive content')")
    }
    try migrations.migrate(database)
    try database.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search WHERE search MATCH 'fictional'")
        #expect(count == 1)
    }
    let backup = try DatabaseQueue(path: root.appendingPathComponent("backup.sqlite").path, configuration: configuration)
    try database.backup(to: backup)
    try backup.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile")
        #expect(count == 1)
    }
    try database.close(); try backup.close()
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(!bytes.starts(with: Data("SQLite format 3".utf8)))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("fictional sensitive content"))
    #expect(throws: (any Error).self) { _ = try DatabaseQueue(path: path) }
    var wrong = Configuration()
    wrong.prepareDatabase { db in try db.usePassphrase("wrong-key-for-test-only") }
    #expect(throws: (any Error).self) { _ = try DatabaseQueue(path: path, configuration: wrong) }
    let reopened = try DatabaseQueue(path: path, configuration: configuration)
    try reopened.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile")
        #expect(count == 1)
    }
    try reopened.close()
}
