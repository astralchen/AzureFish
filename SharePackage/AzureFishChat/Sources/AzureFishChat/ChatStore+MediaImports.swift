import AzureFishStorage
import Foundation
import GRDB

extension ChatStore {
    /// 基线后的追加迁移；导入日志和业务引用同处于账号加密数据库。
    public nonisolated static var mediaImportMigration: AccountMigration {
        AccountMigration("chat-media-import-v1") { db in
            try db.create(table: "media_import_resource") { table in
                table.column("batch", .text).notNull()
                table.column("resource_id", .text).notNull()
                table.primaryKey(["batch", "resource_id"])
            }
        }
    }

    /// 为本次导入分配批次身份；开始写文件前必须登记资源。
    public func beginMediaImport() throws -> UUID { try check(); return UUID() }

    /// 登记资源的暂时引用；也可保护复用资源到业务提交完成。
    public func retainImportedResource(_ resource: UUID, batch: UUID) throws {
        try check()
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO media_import_resource(batch, resource_id) VALUES (?, ?)",
                           arguments: [batch.uuidString, resource.uuidString.lowercased()])
        }
    }

    /// 先登记日志再导入文件；调用方必须提交业务引用或取消整个批次。
    public func importMedia(_ source: URL, filename: String, mime: String, role: String = "original",
                            using media: ChatMediaStore, batch: UUID) async throws -> ChatLocalMedia {
        let id = UUID()
        try retainImportedResource(id, batch: batch)
        return try await media.importFile(source, filename: filename, mime: mime, role: role, id: id)
    }

    static func completeMediaImport(_ batch: UUID?, db: Database) throws {
        guard let batch else { return }
        // 同时登记清理候选，未被本次业务实际引用的导入也能回收。
        try db.execute(sql: "INSERT OR IGNORE INTO media_cleanup_request(resource_id) SELECT resource_id FROM media_import_resource WHERE batch = ?",
                       arguments: [batch.uuidString])
        try db.execute(sql: "DELETE FROM media_import_resource WHERE batch = ?", arguments: [batch.uuidString])
    }

    /// 释放失败批次的暂时引用，留下可重试清理请求；不直接删除文件。
    public func cancelMediaImport(_ batch: UUID) throws {
        try check(); try db.write { try Self.completeMediaImport(batch, db: $0) }
    }

    /// 仅在账号资源首次打开、尚无导入任务时恢复遗留批次。
    public func recoverMediaImports(using media: ChatMediaStore) async throws {
        try check()
        try db.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO media_cleanup_request(resource_id) SELECT resource_id FROM media_import_resource")
            try db.execute(sql: "DELETE FROM media_import_resource")
        }
        try await cleanupMedia(using: media)
    }

    nonisolated static func hasImportReference(_ id: UUID, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM media_import_resource WHERE resource_id = ?)",
                          arguments: [id.uuidString.lowercased()]) == true
    }
}
