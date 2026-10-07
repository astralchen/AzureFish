import AzureFishAPI
import AzureFishStorage
import Foundation

public typealias ChatMediaStoreError = MediaStorageError
public struct ChatLocalMedia: Codable, Sendable {
    /// 聊天媒体在本机加密存储中的稳定 UUID。
    public let id: UUID
    /// 网络上传及缓存恢复所需的资源清单，不包含临时文件路径。
    public let input: ChatMediaInput
    /// 保存本机资源身份和上传清单，不读写文件。
    public init(id: UUID, input: ChatMediaInput) { self.id = id; self.input = input }
}

/// 将聊天网络资源描述映射到账号共享的加密文件存储。
public actor ChatMediaStore {
    /// 底层加密存储使用的固定分块字节数，当前为 4 MiB。
    public static let chunkBytes = EncryptedMediaStore.chunkBytes
    /// 此适配器持有的账号加密媒体存储。
    private let storage: EncryptedMediaStore
    /// 复用账号已有的加密媒体存储，不重新打开目录或清理租约。
    public init(storage: EncryptedMediaStore) { self.storage = storage }
    /// 为指定环境和账号打开加密媒体存储；验证 32 字节密钥及目录身份，并清理遗留明文租约。
    public init(root: URL, key: Data, environment: String, userID: UUID) throws {
        storage = try EncryptedMediaStore(root: root, key: key, environment: environment, userID: userID)
    }
    /// 将聊天资源清单转换为通用描述并准备缓存；同身份恢复须匹配长度、摘要和用途。
    public func prepare(id: UUID, input: ChatMediaInput) async throws {
        try await storage.prepare(id: id, input: .init(role: input.role, filename: input.filename,
            mime: input.mime, bytes: input.bytes, sha256: input.sha256))
    }
    /// 分块导入临时源文件并校验完整摘要，返回本机资源身份及聊天元数据；底层失败原样抛出。
    public func importFile(_ source: URL, filename: String, mime: String, role: String = "original", id: UUID = UUID()) async throws -> ChatLocalMedia {
        let value = try await storage.importFile(source, filename: filename, mime: mime, role: role, id: id)
        return .init(id: value.id, input: .init(role: value.input.role, filename: value.input.filename,
            mime: value.input.mime, bytes: value.input.bytes, sha256: value.input.sha256))
    }
    /// 返回清单已登记的分块序号集合，不在此处重新验证磁盘分块。
    public func completed(_ id: UUID) async throws -> Set<Int> { try await storage.completed(id) }
    /// 将从 0 开始的指定分块校验并加密写入账号媒体存储。
    public func write(_ bytes: Data, id: UUID, index: Int) async throws { try await storage.write(bytes, id: id, index: index) }
    /// 读取从 0 开始的指定分块，返回通过认证及摘要校验的明文字节。
    public func read(_ id: UUID, index: Int) async throws -> Data { try await storage.read(id, index: index) }
    /// 校验整文件摘要并设置完整标记；失败时不能据此资源创建播放租约。
    public func verify(_ id: UUID) async throws { try await storage.verify(id) }
    /// 为已通过完整校验的资源创建临时明文文件；调用方使用结束须 release，定时清理只作补充。
    public func lease(_ id: UUID) async throws -> URL { try await storage.lease(id) }
    /// 释放本存储创建的临时明文租约并取消其清理任务，文件系统错误原样抛出。
    public func release(_ url: URL) async throws { try await storage.release(url) }
    /// 清理当前账号全部临时明文租约；调用前应结束播放器、分享等组件的文件访问。
    public func clearLeases() async throws { try await storage.clearLeases() }
    /// 在账号数据库排他写入区间检查全部业务引用，仅未被引用时删除加密资源并返回 true。
    func removeIfUnreferenced(_ id: UUID, database: AccountDatabase) async throws -> Bool {
        try await storage.removeIfUnreferenced(id, database: database)
    }
    /// 返回受保护临时目录中的目标地址，尚不创建文件；调用方写入并在使用结束后 release。
    public func temporaryFile(filename: String) async throws -> URL { try await storage.temporaryFile(filename: filename) }
}
