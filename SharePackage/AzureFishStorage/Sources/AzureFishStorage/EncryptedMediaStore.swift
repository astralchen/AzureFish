import CryptoKit
import Foundation

/// 与网络协议无关的资源描述；摘要采用 SHA-256，长度单位为字节。
public struct MediaResourceDescriptor: Codable, Sendable, Equatable {
    /// 资源在资产中的用途，例如 original 或 thumbnail。
    public let role: String
    /// 资源文件名，仅为元数据，不是本地文件路径。
    public let filename: String
    /// 资源的 MIME 类型字符串。
    public let mime: String
    /// 资源完整长度，单位为字节。
    public let bytes: Int64
    /// 完整资源内容的 SHA-256 十六进制摘要。
    public let sha256: String
    /// 保存资源用途、文件名、MIME、字节数和摘要；默认用途为 original，约束由存储操作校验。
    public init(role: String = "original", filename: String, mime: String, bytes: Int64, sha256: String) {
        self.role = role; self.filename = filename; self.mime = mime; self.bytes = bytes; self.sha256 = sha256
    }
}

public enum MediaStorageError: Error, Sendable { case integrity, unavailable, invalidResource }
public struct LocalMediaResource: Codable, Sendable {
    /// 本机加密资源的稳定 UUID。
    public let id: UUID
    /// 该资源的用途、类型、完整字节数和摘要快照。
    public let input: MediaResourceDescriptor
}
/// 分块 AES-GCM 本机缓存；每个资源独立随机密钥，清单与分块均绑定账号及用途。
public actor EncryptedMediaStore {
    /// 固定分块大小，单位为字节，当前为 4 MiB；最后一块可更短。
    public static let chunkBytes = 4 * 1024 * 1024
    /// 当前环境及账号的加密媒体根目录。
    private let root: URL
    /// 位于根目录 leases 下的临时明文目录，打开存储时清理遗留内容。
    private let temporary: URL
    /// 用于封装资源密钥及认证存储身份的主密钥，不与资源分块直接共用。
    private let wrappingKey: SymmetricKey
    /// 环境标识与用户 UUID 组合的认证作用域，参与身份及资源附加认证数据。
    private let scope: String
    /// 按临时文件地址登记的到期清理任务；主动释放时取消对应任务。
    private var leaseExpirations: [URL: Task<Void, Never>] = [:]
    private struct Manifest: Codable {
        /// 创建资源时保存的用途、字节数及完整摘要。
        var input: MediaResourceDescriptor
        /// 已保存分块的序号到明文 SHA-256 摘要映射。
        var parts: [Int: String]
        /// 是否已通过整文件摘要验证；新清单初始为 false。
        var complete: Bool
    }
    /// 验证 32 字节主密钥和账号目录身份，创建受保护目录并清理上次遗留的明文租约。
    ///
    /// 非空旧目录缺少身份文件时拒绝打开；认证失败不会生成新身份覆盖。
    /// - Throws: 密钥长度、身份认证或文件系统操作错误。
    public init(root: URL, key: Data, environment: String, userID: UUID) throws {
        guard key.count == 32 else { throw AccountStorageError.invalidKey }
        self.root = root
        temporary = root.appendingPathComponent("leases", isDirectory: true)
        wrappingKey = SymmetricKey(data: key)
        scope = environment + ":" + userID.uuidString.lowercased()
        try Self.directory(root)
        let identityURL = root.appendingPathComponent("identity")
        let identityAAD = Data((scope + ":media-store:v1").utf8)
        if FileManager.default.fileExists(atPath: identityURL.path) {
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: identityURL))
            guard try AES.GCM.open(box, using: wrappingKey, authenticating: identityAAD) == Data("chat-media-v1".utf8) else {
                throw MediaStorageError.integrity
            }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw MediaStorageError.integrity }
            guard let bytes = try AES.GCM.seal(Data("chat-media-v1".utf8), using: wrappingKey, authenticating: identityAAD).combined else {
                throw MediaStorageError.integrity
            }
            try bytes.write(to: identityURL, options: .atomic)
        }
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        try Self.directory(temporary)
    }
    /// 创建仅当前用户可访问且排除备份的目录；iOS 同时设置首次解锁后文件保护。
    private static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    /// 返回指定资源 UUID 小写名称的目录地址，不创建目录。
    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
    /// 组合账号作用域、资源身份、格式版本和用途，生成 AES-GCM 附加认证数据。
    private func aad(_ id: UUID, _ purpose: String) -> Data {
        Data((scope + ":" + id.uuidString.lowercased() + ":v1:" + purpose).utf8)
    }
    /// 使用给定密钥及附加认证数据封装字节，返回包含 nonce 和标签的 AES-GCM 数据。
    private func seal(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let data = try AES.GCM.seal(bytes, using: key, authenticating: aad).combined else {
            throw MediaStorageError.integrity
        }
        return data
    }
    /// 验证 AES-GCM 标签及附加认证数据并解密；篡改、错误密钥或用途不符时抛错。
    private func open(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad)
    }
    /// 读取并用主密钥解封指定资源的独立密钥；不在读取失败时生成替代密钥。
    private func key(_ id: UUID) throws -> SymmetricKey {
        SymmetricKey(
            data: try open(
                Data(contentsOf: folder(id).appendingPathComponent("key")), key: wrappingKey, aad: aad(id, "key")))
    }
    /// 认证解密指定资源的清单并解码其元数据和分块状态。
    private func manifest(_ id: UUID) throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: open(
                Data(contentsOf: folder(id).appendingPathComponent("manifest")), key: key(id), aad: aad(id, "manifest"))
        )
    }
    /// 用资源密钥加密清单并原子替换清单文件；调用方负责先保存对应分块。
    private func save(_ manifest: Manifest, id: UUID) throws {
        try seal(JSONEncoder().encode(manifest), key: key(id), aad: aad(id, "manifest")).write(
            to: folder(id).appendingPathComponent("manifest"), options: .atomic)
    }
    /// 创建下载缓存；同一身份恢复须保持长度、摘要和用途一致，不覆盖已有文件名或 MIME。
    ///
    /// - Parameter input: 完整资源描述；新资源长度须大于 0 且不超过 512 MiB，摘要用于后续完整校验。
    /// - Throws: 已有身份元数据不匹配、新资源大小无效，或加密及文件系统错误。
    public func prepare(id: UUID, input: MediaResourceDescriptor) throws {
        let dir = folder(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            let old = try manifest(id).input
            guard old.bytes == input.bytes, old.sha256 == input.sha256, old.role == input.role else {
                throw MediaStorageError.integrity
            }
            return
        }
        guard input.bytes > 0, input.bytes <= 512 * 1024 * 1024 else { throw MediaStorageError.invalidResource }
        try Self.directory(dir)
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try seal(bytes, key: wrappingKey, aad: aad(id, "key")).write(
            to: dir.appendingPathComponent("key"), options: .atomic)
        try save(Manifest(input: input, parts: [:], complete: false), id: id)
    }
    /// 从系统提供的临时资源流式导入；不创建整文件 Data 副本。
    public func importFile(_ source: URL, filename: String, mime: String, role: String = "original", id: UUID = UUID()) throws
        -> LocalMediaResource
    {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= 512 * 1024 * 1024 else { throw MediaStorageError.invalidResource }
            hasher.update(data: data)
        }
        let safe = URL(fileURLWithPath: filename).lastPathComponent
        let input = MediaResourceDescriptor(
            role: role, filename: safe, mime: mime, bytes: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        try prepare(id: id, input: input)
        try handle.seek(toOffset: 0)
        var index = 0
        while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
            try write(data, id: id, index: index)
            index += 1
        }
        try verify(id)
        // 导入补偿由账号业务事务检查全部引用后执行，不能在这里删除同身份资源。
        return LocalMediaResource(id: id, input: input)
    }
    /// 返回清单已登记的从 0 开始的分块序号集合；不在此处重新读取或验证分块文件。
    public func completed(_ id: UUID) throws -> Set<Int> { Set(try manifest(id).parts.keys) }
    /// 校验分块位置及长度后加密保存，再登记摘要；同位置已有相同摘要时直接返回。
    ///
    /// - Parameters:
    ///   - bytes: 完整分块内容，长度须匹配资源长度及分块位置。
    ///   - id: 已经 prepare 的资源身份。
    ///   - index: 从 0 开始的分块序号。
    /// - Throws: 任务取消、分块不匹配、加密或文件系统错误。
    public func write(_ bytes: Data, id: UUID, index: Int) throws {
        try Task.checkCancellation()
        var manifest = try manifest(id)
        let expected = min(Int64(Self.chunkBytes), manifest.input.bytes - Int64(index) * Int64(Self.chunkBytes))
        guard index >= 0, expected > 0, bytes.count == expected else { throw MediaStorageError.integrity }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let old = manifest.parts[index] {
            guard old == digest else { throw MediaStorageError.integrity }
            return
        }
        let encrypted = try seal(bytes, key: key(id), aad: aad(id, "part:\(index):\(bytes.count)"))
        try encrypted.write(to: folder(id).appendingPathComponent("\(index).blob"), options: .atomic)
        manifest.parts[index] = digest
        try save(manifest, id: id)
    }
    /// 认证解密指定分块，并校验长度及清单摘要。
    ///
    /// - Parameter index: 从 0 开始的分块序号。
    /// - Returns: 校验通过的明文字节，仅供调用方临时使用。
    /// - Throws: 分块未登记时为 unavailable，完整性不符或读取失败时抛出对应错误。
    public func read(_ id: UUID, index: Int) throws -> Data {
        let manifest = try manifest(id)
        let count = min(Int64(Self.chunkBytes), manifest.input.bytes - Int64(index) * Int64(Self.chunkBytes))
        guard index >= 0, count > 0, let expected = manifest.parts[index] else { throw MediaStorageError.unavailable }
        let data = try open(
            Data(contentsOf: folder(id).appendingPathComponent("\(index).blob")), key: key(id),
            aad: aad(id, "part:\(index):\(count)"))
        guard data.count == count, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected
        else { throw MediaStorageError.integrity }
        return data
    }
    /// 依次读取全部分块并校验整文件 SHA-256，成功后持久化完整标记；取消或校验失败会抛错。
    public func verify(_ id: UUID) throws {
        var manifest = try manifest(id)
        var hash = SHA256()
        let count = Int((manifest.input.bytes + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))
        for index in 0..<count {
            try Task.checkCancellation()
            hash.update(data: try read(id, index: index))
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.input.sha256 else {
            throw MediaStorageError.integrity
        }
        manifest.complete = true
        try save(manifest, id: id)
    }
    /// 为整文件校验通过的资源生成播放或分享所需的临时明文文件。
    ///
    /// 调用方应在使用结束后调用 release。约一小时后会尝试自动释放；调度或删除失败时，
    /// 遗留内容由 clearLeases 或下次打开存储清理，不保证在固定截止时间前完成删除。
    ///
    /// - Returns: 当前账号受保护且排除备份的租约文件地址。
    /// - Throws: 资源尚未完整校验、任务取消、分块认证或文件系统错误。
    public func lease(_ id: UUID) throws -> URL {
        let manifest = try manifest(id)
        guard manifest.complete else { throw MediaStorageError.unavailable }
        let directory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.directory(directory)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: manifest.input.filename).lastPathComponent)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw MediaStorageError.unavailable }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        do {
            let count = Int((manifest.input.bytes + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))
            for index in 0..<count {
                try Task.checkCancellation()
                try handle.write(contentsOf: read(id, index: index))
            }
            expire(url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    /// 取消指定租约的到期任务并删除其临时目录；目录已不存在时直接返回。
    ///
    /// 地址必须位于本存储的两级租约目录结构内，否则抛出 invalidResource。
    public func release(_ url: URL) throws {
        guard
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == temporary.standardizedFileURL
        else { throw MediaStorageError.invalidResource }
        leaseExpirations.removeValue(forKey: url)?.cancel()
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
    /// 取消全部到期任务，删除并重建临时明文目录；调用前应结束系统组件对文件的使用。
    ///
    /// 目录已被清理时可重复调用；账号根目录已移除时不重新创建它。
    public func clearLeases() throws {
        for task in leaseExpirations.values { task.cancel() }
        leaseExpirations.removeAll()
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        try Self.directory(temporary)
    }
    /// 只清理账号所有业务均未引用的资源；引用检查和文件删除与数据库写入互斥。
    public func removeIfUnreferenced(_ id: UUID, database: AccountDatabase) throws -> Bool {
        guard database.environment + ":" + database.userID.uuidString.lowercased() == scope else { throw MediaStorageError.unavailable }
        let url = folder(id)
        return try database.removeResourceIfUnreferenced(id) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    /// 为临时文件登记约一小时后的释放尝试；取消、任务或删除错误在此任务内忽略。
    private func expire(_ url: URL) {
        leaseExpirations[url] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000); try await self?.release(url) } catch {}
        }
    }
    /// 取消已登记的到期任务；不在析构中同步删除文件，遗留明文由下次打开清理。
    deinit { for task in leaseExpirations.values { task.cancel() } }
}

extension EncryptedMediaStore {
    /// 创建系统导入或录音使用的受保护临时目录，返回尚未创建的目标文件地址。
    ///
    /// filename 仅保留最后一个路径分量；调用方负责写入文件并在使用结束后 release。
    /// 同时登记约一小时后的清理尝试，遗留内容在下次打开时清理。
    public func temporaryFile(filename: String) throws -> URL {
        let directory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.directory(directory)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        expire(url)
        return url
    }
}
