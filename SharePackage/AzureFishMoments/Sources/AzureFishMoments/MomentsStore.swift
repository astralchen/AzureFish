import AzureFishAPI
import AzureFishStorage
import Foundation
import GRDB

/// 加密媒体的本地身份及上传恢复信息；图片、视频和封面共用此记录。
public struct MomentsImageDraft: Codable, Sendable, Identifiable {
    public var id: UUID
    public var descriptor: MediaResourceDescriptor
    /// 创建服务端资产的幂等身份；断点恢复时与原始资源描述一起复用。
    public var createOperation = UUID()
    /// 完成上传的幂等身份，与创建资产的操作身份独立。
    public var completeOperation = UUID()
    /// 已创建的服务端资产 ID；nil 表示尚未保存创建结果。
    public var assetID: String?
    public init(id: UUID, descriptor: MediaResourceDescriptor) { self.id = id; self.descriptor = descriptor }
}
/// 视频源和导出文件分别加密；未完成导出时 output 为 nil，可在重启后重新裁剪。
public struct MomentsVideoDraft: Codable, Sendable {
    public var source: MomentsImageDraft
    public var output: MomentsImageDraft?
    public var poster: MomentsImageDraft?
    /// 已导出视频的时长，单位为毫秒；未导出时为零。
    public var duration: Int64 = 0
    public var width: Int32 = 0
    public var height: Int32 = 0
    /// 系统裁剪器不公开起点；选段由加密 output 文件精确保存。
    public var trimStart: Double?
    /// 已选视频片段的时长，单位为秒，初始值为 60。
    public var trimDuration: Double = 60
    public init(source: MomentsImageDraft) { self.source = source }
    public var resources: [UUID] { [source.id] + [output?.id, poster?.id].compactMap { $0 } }
}
/// 草稿按独立 UUID 隔离窗口；publication 非 nil 后内容冻结，只可对账或重试。
public struct MomentsDraft: Codable, Sendable, Identifiable {
    public var id: UUID
    public var operation = UUID()
    public var text = ""
    public var isCover = false
    public var coverRevision: Int64 = 0
    public var coverAsset: String?
    public var images: [MomentsImageDraft] = []
    public var video: MomentsVideoDraft?
    public var resources: [UUID] { images.map(\.id) + (video?.resources ?? []) }
    /// 首次发布前持久化的完整请求字节；非 nil 时重试必须原样复用。
    public var publication: Data?
    public var updatedAt = Date()
    public init(id: UUID = UUID()) { self.id = id }
}
/// 已登记的互动或封面请求；未知结果时保留原身份和参数供显式重试。
public struct MomentsPendingAction: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case like, deletePost, comment, deleteComment, cover }
    public var id: UUID
    public var kind: Kind
    public var post: String
    public var liked: Bool
    public var comment: String
    public var text: String
    public var replyTo: String
    public var asset: String
    public var revision: Int64
    public init(kind: Kind, post: String = "", liked: Bool = false, comment: String = UUID().uuidString.lowercased(),
                text: String = "", replyTo: String = "", asset: String = "", revision: Int64 = 0, id: UUID = UUID()) {
        self.id = id; self.kind = kind; self.post = post; self.liked = liked; self.comment = comment
        self.text = text; self.replyTo = replyTo; self.asset = asset; self.revision = revision
    }
}
/// 借用账号 SQLCipher 连接，不拥有底层关闭权；迁移由账号存储统一登记。
public actor MomentsStore {
    /// 在账号数据库中建立快照、媒体引用和待清理记录表。
    public static let migration = AccountMigration("moments-v1") { db in
        try db.create(table: "moments_items") { t in
            t.column("id", .text).primaryKey(); t.column("kind", .text).notNull()
            t.column("payload", .blob).notNull(); t.column("revision", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "moments_cleanup") { $0.column("resource", .text).primaryKey() }
        try db.create(table: "moments_resources") { t in
            t.column("parent", .text).notNull(); t.column("resource", .text).notNull()
            t.primaryKey(["parent", "resource"])
        }
    }
    /// 借用的账号数据库；本存储关闭时不关闭此连接。
    public let database: AccountDatabase
    private var closed = false
    public init(database: AccountDatabase) throws {
        self.database = database
        try database.registerResourceReferences(domain: "moments") { db, id in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM moments_resources WHERE resource = ?)", arguments: [id.uuidString.lowercased()]) ?? false
        }
    }
    /// 拒绝后续受检查的存储操作；调用方应先等待已登记的账号任务结束。
    public func close() { closed = true }
    private func check() throws { try Task.checkCancellation(); if closed { throw AccountStorageError.unavailable } }
    private func put<T: Encodable>(_ value: T, id: String, kind: String, revision: Int64 = 0, resources: [String] = []) throws {
        try check(); let bytes = try JSONEncoder().encode(value)
        try database.write { db in
            // 旧快照不能覆盖新版本；同版本仍允许更新好友权限过滤后的内容。
            if let old = try Int64.fetchOne(db, sql: "SELECT revision FROM moments_items WHERE id = ?", arguments: [id]), old > revision { return }
            try db.execute(sql: "INSERT OR REPLACE INTO moments_items (id, kind, payload, revision) VALUES (?, ?, ?, ?)", arguments: [id, kind, bytes, revision])
            let previous = try String.fetchAll(db, sql: "SELECT resource FROM moments_resources WHERE parent = ?", arguments: [id])
            // 引用替换和清理登记在同一事务提交，文件删除失败后仍可恢复。
            for resource in Set(previous).subtracting(Set(resources.map { $0.lowercased() })) {
                try db.execute(sql: "INSERT OR IGNORE INTO moments_cleanup (resource) VALUES (?)", arguments: [resource])
            }
            try db.execute(sql: "DELETE FROM moments_resources WHERE parent = ?", arguments: [id])
            for resource in Set(resources) {
                try db.execute(sql: "INSERT INTO moments_resources (parent, resource) VALUES (?, ?)", arguments: [id, resource.lowercased()])
            }
        }
    }
    private func values<T: Decodable>(_ kind: String, as: T.Type) throws -> [T] {
        try check()
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM moments_items WHERE kind = ?", arguments: [kind]).map { try JSONDecoder().decode(T.self, from: $0) }
        }
    }
    /// 返回未删除的缓存动态，按 sequence、ID 降序排列；author 为空时包含所有作者。
    public func posts(author: String = "") throws -> [MomentsPost] {
        try values("post", as: MomentsPost.self).filter { !$0.deleted && (author.isEmpty || $0.author.id == author) }
            .sorted { $0.sequence == $1.sequence ? $0.id > $1.id : $0.sequence > $1.sequence }
    }
    /// 按版本合并动态及媒体引用；每条动态独立提交，失败时先前条目可能已保存。
    public func merge(_ posts: [MomentsPost]) throws {
        for post in posts { try put(post, id: "post:" + post.id, kind: "post", revision: post.revision, resources: (post.images + [post.video].compactMap { $0 }).flatMap { $0.resources.map(\.id) }) }
    }
    /// 移除指定动态快照并登记资源清理，不向服务端发起删除请求。
    public func removePosts(_ ids: [String]) throws { for id in ids { try remove("post:" + id) } }
    /// 移除指定作者的可见缓存动态和相册，并登记资源清理。
    public func removeAuthor(_ id: String) throws {
        for post in try posts(author: id) { try remove("post:" + post.id) }
        try remove("album:" + id)
    }
    /// 保存相册和封面引用；较旧版本不会覆盖已缓存的相册。
    public func save(_ album: MomentsAlbum) throws {
        try put(album, id: "album:" + album.owner.id, kind: "album", revision: album.revision, resources: album.cover?.resources.map(\.id) ?? [])
    }
    /// 检查指定动态或相册当前是否仍引用资源，避免迟到下载重新显示失权图片。
    public func containsResource(_ id: UUID, target: String, cover: Bool) throws -> Bool {
        try check()
        return try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM moments_resources WHERE parent = ? AND resource = ?)",
                arguments: [(cover ? "album:" : "post:") + target, id.uuidString.lowercased()]) ?? false
        }
    }
    /// 返回缓存相册；结果顺序未作约定。
    public func albums() throws -> [MomentsAlbum] { try values("album", as: MomentsAlbum.self) }
    /// 返回指定所有者的缓存相册；尚未缓存时返回 nil。
    public func album(_ owner: String) throws -> MomentsAlbum? { try values("album", as: MomentsAlbum.self).first { $0.owner.id == owner } }
    /// 保存完整草稿并替换媒体引用；调用方负责避免过时编辑覆盖新内容。
    public func save(_ draft: MomentsDraft) throws {
        try put(draft, id: "draft:" + draft.id.uuidString, kind: "draft", resources: draft.resources.map { $0.uuidString })
    }
    /// 返回按最后编辑时间降序排列的草稿。
    public func drafts() throws -> [MomentsDraft] { try values("draft", as: MomentsDraft.self).sorted { $0.updatedAt > $1.updatedAt } }
    /// 删除草稿并登记其媒体清理；实际文件由后续清理操作按引用决定是否删除。
    public func removeDraft(_ id: UUID) throws { try remove("draft:" + id.uuidString) }
    /// 按操作 ID 保存待重试请求，必须在发起网络写入前调用。
    public func save(_ action: MomentsPendingAction) throws { try put(action, id: "action:" + action.id.uuidString, kind: "action") }
    /// 返回待重试请求；不保证顺序，也不自动执行请求。
    public func pending() throws -> [MomentsPendingAction] { try values("action", as: MomentsPendingAction.self) }
    /// 移除已完成或已明确拒绝的待重试请求。
    public func removeAction(_ id: UUID) throws { try remove("action:" + id.uuidString) }
    /// 先登记引用再进行导入，启动时可清理没有归属草稿的中断资源。
    public func reserve(_ id: UUID) throws { try put(id, id: "import:" + id.uuidString, kind: "import", resources: [id.uuidString]) }
    /// 撤销导入预留；成功导入时应先保存草稿引用，再调用此方法。
    public func finishImport(_ id: UUID) throws { try remove("import:" + id.uuidString) }
    /// 清理中断的导入预留；已被草稿等账号数据引用的资源继续保留。
    public func recoverImports(media: EncryptedMediaStore) async throws {
        for id in try values("import", as: UUID.self) {
            // 先释放预留引用，保留恢复记录直到文件清理成功。
            try database.write { db in
                try db.execute(sql: "DELETE FROM moments_resources WHERE parent = ?", arguments: ["import:" + id.uuidString])
            }
            _ = try await media.removeIfUnreferenced(id, database: database)
            try finishImport(id)
        }
    }
    /// 清理失权、删除和替换后失去引用的加密文件；共享资源仍由账号级引用检查保护。
    public func recoverCleanup(media: EncryptedMediaStore) async throws {
        try check()
        let resources = try database.read { try String.fetchAll($0, sql: "SELECT resource FROM moments_cleanup") }
        for resource in resources {
            guard let id = UUID(uuidString: resource) else { throw MediaStorageError.invalidResource }
            _ = try await media.removeIfUnreferenced(id, database: database)
            try database.write { try $0.execute(sql: "DELETE FROM moments_cleanup WHERE resource = ?", arguments: [resource]) }
        }
    }
    /// 仅在账号各业务域均不再引用资源时删除其加密文件。
    public func releaseResource(_ id: UUID, media: EncryptedMediaStore) async throws {
        try check(); _ = try await media.removeIfUnreferenced(id, database: database)
    }
    private func remove(_ id: String) throws {
        try check()
        try database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO moments_cleanup (resource) SELECT resource FROM moments_resources WHERE parent = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM moments_items WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM moments_resources WHERE parent = ?", arguments: [id])
        }
    }
}
