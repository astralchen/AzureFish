import AzureFishAPI
import CryptoKit
import Foundation

public enum ChatMediaStoreError: Error, Sendable { case integrity, unavailable, invalidResource }
public struct ChatLocalMedia: Codable, Sendable {
    public let id: UUID
    public let input: ChatMediaInput
}
/// 分块 AES-GCM 本机缓存；每个资源独立随机密钥，清单与分块均绑定账号及用途。
public actor ChatMediaStore {
    public static let chunkBytes = 4 * 1024 * 1024
    private let root: URL
    private let temporary: URL
    private let wrappingKey: SymmetricKey
    private let scope: String
    private var leaseExpirations: [URL: Task<Void, Never>] = [:]
    private struct Manifest: Codable {
        var input: ChatMediaInput
        var parts: [Int: String]
        var complete: Bool
    }
    public init(root: URL, key: Data, environment: String, userID: UUID) throws {
        guard key.count == 32 else { throw ChatStoreError.invalidKey }
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
                throw ChatMediaStoreError.integrity
            }
        } else {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw ChatMediaStoreError.integrity }
            guard let bytes = try AES.GCM.seal(Data("chat-media-v1".utf8), using: wrappingKey, authenticating: identityAAD).combined else {
                throw ChatMediaStoreError.integrity
            }
            try bytes.write(to: identityURL, options: .atomic)
        }
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        try Self.directory(temporary)
    }
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
    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }
    private func aad(_ id: UUID, _ purpose: String) -> Data {
        Data((scope + ":" + id.uuidString.lowercased() + ":v1:" + purpose).utf8)
    }
    private func seal(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let data = try AES.GCM.seal(bytes, using: key, authenticating: aad).combined else {
            throw ChatMediaStoreError.integrity
        }
        return data
    }
    private func open(_ bytes: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: aad)
    }
    private func key(_ id: UUID) throws -> SymmetricKey {
        SymmetricKey(
            data: try open(
                Data(contentsOf: folder(id).appendingPathComponent("key")), key: wrappingKey, aad: aad(id, "key")))
    }
    private func manifest(_ id: UUID) throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: open(
                Data(contentsOf: folder(id).appendingPathComponent("manifest")), key: key(id), aad: aad(id, "manifest"))
        )
    }
    private func save(_ manifest: Manifest, id: UUID) throws {
        try seal(JSONEncoder().encode(manifest), key: key(id), aad: aad(id, "manifest")).write(
            to: folder(id).appendingPathComponent("manifest"), options: .atomic)
    }
    /// 创建下载缓存；同一身份的恢复只接受完全一致的权威长度与摘要。
    public func prepare(id: UUID, input: ChatMediaInput) throws {
        let dir = folder(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            let old = try manifest(id).input
            guard old.bytes == input.bytes, old.sha256 == input.sha256, old.role == input.role else {
                throw ChatMediaStoreError.integrity
            }
            return
        }
        guard input.bytes > 0, input.bytes <= 512 * 1024 * 1024 else { throw ChatMediaStoreError.invalidResource }
        try Self.directory(dir)
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try seal(bytes, key: wrappingKey, aad: aad(id, "key")).write(
            to: dir.appendingPathComponent("key"), options: .atomic)
        try save(Manifest(input: input, parts: [:], complete: false), id: id)
    }
    /// 从系统提供的临时资源流式导入；不创建整文件 Data 副本。
    public func importFile(_ source: URL, filename: String, mime: String, role: String = "original") throws
        -> ChatLocalMedia
    {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            total += Int64(data.count)
            guard total <= 512 * 1024 * 1024 else { throw ChatMediaStoreError.invalidResource }
            hasher.update(data: data)
        }
        let safe = URL(fileURLWithPath: filename).lastPathComponent
        let input = ChatMediaInput(
            role: role, filename: safe, mime: mime, bytes: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        let id = UUID()
        try prepare(id: id, input: input)
        try handle.seek(toOffset: 0)
        var index = 0
        do {
            while let data = try handle.read(upToCount: Self.chunkBytes), !data.isEmpty {
                try write(data, id: id, index: index)
                index += 1
            }
            try verify(id)
            return ChatLocalMedia(id: id, input: input)
        } catch {
            try? remove(id)
            throw error
        }
    }
    public func completed(_ id: UUID) throws -> Set<Int> { Set(try manifest(id).parts.keys) }
    public func write(_ bytes: Data, id: UUID, index: Int) throws {
        try Task.checkCancellation()
        var manifest = try manifest(id)
        let expected = min(Int64(Self.chunkBytes), manifest.input.bytes - Int64(index) * Int64(Self.chunkBytes))
        guard index >= 0, expected > 0, bytes.count == expected else { throw ChatMediaStoreError.integrity }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let old = manifest.parts[index] {
            guard old == digest else { throw ChatMediaStoreError.integrity }
            return
        }
        let encrypted = try seal(bytes, key: key(id), aad: aad(id, "part:\(index):\(bytes.count)"))
        try encrypted.write(to: folder(id).appendingPathComponent("\(index).blob"), options: .atomic)
        manifest.parts[index] = digest
        try save(manifest, id: id)
    }
    public func read(_ id: UUID, index: Int) throws -> Data {
        let manifest = try manifest(id)
        let count = min(Int64(Self.chunkBytes), manifest.input.bytes - Int64(index) * Int64(Self.chunkBytes))
        guard index >= 0, count > 0, let expected = manifest.parts[index] else { throw ChatMediaStoreError.unavailable }
        let data = try open(
            Data(contentsOf: folder(id).appendingPathComponent("\(index).blob")), key: key(id),
            aad: aad(id, "part:\(index):\(count)"))
        guard data.count == count, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected
        else { throw ChatMediaStoreError.integrity }
        return data
    }
    public func verify(_ id: UUID) throws {
        var manifest = try manifest(id)
        var hash = SHA256()
        let count = Int((manifest.input.bytes + Int64(Self.chunkBytes) - 1) / Int64(Self.chunkBytes))
        for index in 0..<count {
            try Task.checkCancellation()
            hash.update(data: try read(id, index: index))
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.input.sha256 else {
            throw ChatMediaStoreError.integrity
        }
        manifest.complete = true
        try save(manifest, id: id)
    }
    /// 仅在整文件校验通过后生成播放／分享租约；使用结束时 release，最迟一小时后清理。
    public func lease(_ id: UUID) throws -> URL {
        let manifest = try manifest(id)
        guard manifest.complete else { throw ChatMediaStoreError.unavailable }
        let directory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.directory(directory)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: manifest.input.filename).lastPathComponent)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw ChatMediaStoreError.unavailable }
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
    public func release(_ url: URL) throws {
        guard
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == temporary.standardizedFileURL
        else { throw ChatMediaStoreError.invalidResource }
        leaseExpirations.removeValue(forKey: url)?.cancel()
        if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }
    public func clearLeases() throws {
        for task in leaseExpirations.values { task.cancel() }
        leaseExpirations.removeAll()
        try FileManager.default.removeItem(at: temporary)
        try Self.directory(temporary)
    }
    public func remove(_ id: UUID) throws {
        if FileManager.default.fileExists(atPath: folder(id).path) { try FileManager.default.removeItem(at: folder(id)) }
    }
    private func expire(_ url: URL) {
        leaseExpirations[url] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_600_000_000_000); try await self?.release(url) } catch {}
        }
    }
    deinit { for task in leaseExpirations.values { task.cancel() } }
}

extension ChatMediaStore {
    /// 创建系统导入／录音的受限临时目标；使用结束必须 release，启动时统一清理。
    public func temporaryFile(filename: String) throws -> URL {
        let directory = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try Self.directory(directory)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        expire(url)
        return url
    }
}
