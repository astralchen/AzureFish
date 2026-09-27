import Crypto
import Foundation
import Vapor
#if canImport(Darwin)
import Darwin
#endif

/// 密文资源存储边界；不接受用户文件名作为磁盘路径。
protocol MediaBlobStore: Sendable {
    var root: URL { get }
    var work: URL { get }
    func io<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T
    func initialize() async throws
    func availableBytes() async throws -> Int64
    func discard(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws
    func put(_ data: Data, ticket: MediaResourceTicket, index: Int) async throws -> MediaChunk
    func read(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws -> Data
    func finish(_ chunks: [MediaChunk], ticket: MediaResourceTicket) async throws -> String
    func manifest(_ ticket: MediaResourceTicket) async throws -> MediaManifest
    func remove(_ resource: UUID) async throws
}

/// 本机 AES-GCM 独立分块与认证清单；阻塞文件操作在线程池运行。
struct LocalMediaBlobStore: MediaBlobStore {
    let root: URL
    let work: URL
    let environment: String
    let app: Application

    func io<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        // Foundation／Crypto 桥接对象必须在每次 IO 后释放，不能留到线程退出。
        try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next()) { try autoreleasepool(invoking: body) }.get()
    }
    func initialize() async throws {
        try await io {
            try Self.directory(root)
            if FileManager.default.fileExists(atPath: work.path) {
                try Self.checkDirectory(work)
                try FileManager.default.removeItem(at: work)
            }
            try Self.directory(work)
            var directory = work; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
    }
    static func directory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try checkDirectory(url)
    }
    static func checkDirectory(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { throw APIError(.internalServerError, "MEDIA_STORAGE_UNAVAILABLE") }
    }
    func resourceDirectory(_ id: UUID) throws -> URL {
        try Self.checkDirectory(root)
        let url = root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try Self.directory(url); return url
    }
    func aad(_ ticket: MediaResourceTicket, purpose: String, index: Int, bytes: Int64) -> Data {
        var data = Data()
        for part in ["azurefish-media", "1", environment, ticket.owner.uuidString, ticket.id.uuidString, ticket.state.role, purpose, String(index), String(bytes)] {
            let value = Data(part.utf8); var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }; data.append(value)
        }
        return data
    }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func atomicWrite(_ bytes: Data, to url: URL) throws {
        // 创建不可预测的新文件，禁止跟随符号链接；同一资源已提交的文件永不覆盖。
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: bytes); try file.synchronize(); try file.close()
            let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
            guard parent >= 0 else { throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
            defer { close(parent) }
            guard fsync(parent) == 0 else { throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
        }
        catch { try? file.close(); try? FileManager.default.removeItem(at: url); throw APIError(.insufficientStorage, "MEDIA_STORAGE_UNAVAILABLE") }
    }
    static func readRegular(_ url: URL, max: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= max else { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
        return try file.readToEnd() ?? Data()
    }
    func put(_ data: Data, ticket: MediaResourceTicket, index: Int) async throws -> MediaChunk {
        guard data.count <= MediaLimits.chunk else { throw APIError(.payloadTooLarge, "PAYLOAD_TOO_LARGE") }
        return try await io {
            let directory = try resourceDirectory(ticket.id)
            let name = UUID().uuidString.lowercased() + ".bin"
            let cipher = try AES.GCM.seal(data, using: SymmetricKey(data: ticket.key), authenticating: aad(ticket, purpose: "chunk", index: index, bytes: Int64(data.count))).combined!
            try Self.atomicWrite(cipher, to: directory.appendingPathComponent(name))
            return MediaChunk(index: index, bytes: data.count, sha256: Self.hash(data), filename: name)
        }
    }
    func readSync(_ chunk: MediaChunk, ticket: MediaResourceTicket) throws -> Data {
        guard chunk.bytes > 0, chunk.bytes <= MediaLimits.chunk, UUID(uuidString: String(chunk.filename.dropLast(4))) != nil,
              chunk.filename.hasSuffix(".bin"), chunk.index >= 0 else { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
        let directory = root.appendingPathComponent(ticket.id.uuidString.lowercased())
        try Self.checkDirectory(root); try Self.checkDirectory(directory)
        let cipher = try Self.readRegular(directory.appendingPathComponent(chunk.filename), max: MediaLimits.chunk + 28)
        do {
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: SymmetricKey(data: ticket.key), authenticating: aad(ticket, purpose: "chunk", index: chunk.index, bytes: Int64(chunk.bytes)))
            guard bytes.count == chunk.bytes, Self.hash(bytes) == chunk.sha256 else { throw ConfigurationError.invalidCiphertext }
            return bytes
        } catch { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
    }
    func read(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws -> Data { try await io { try readSync(chunk, ticket: ticket) } }
    func finish(_ chunks: [MediaChunk], ticket: MediaResourceTicket) async throws -> String {
        try await io {
            var hash = SHA256(); var total: Int64 = 0
            for (index, chunk) in chunks.enumerated() {
                guard chunk.index == index, chunk.bytes == min(MediaLimits.chunk, Int(ticket.state.bytes - total)) else { throw APIError(.conflict, "UPLOAD_INCOMPLETE") }
                try autoreleasepool {
                    let bytes = try readSync(chunk, ticket: ticket); hash.update(data: bytes); total += Int64(bytes.count)
                }
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard total == ticket.state.bytes, digest == ticket.state.sha256 else { throw APIError(.unprocessableEntity, "CONTENT_DIGEST_MISMATCH") }
            let manifest = MediaManifest(bytes: total, sha256: digest, chunks: chunks)
            let encrypted = try AES.GCM.seal(JSONEncoder().encode(manifest), using: SymmetricKey(data: ticket.key), authenticating: aad(ticket, purpose: "manifest", index: 0, bytes: total)).combined!
            let filename = UUID().uuidString.lowercased() + ".manifest"
            try Self.atomicWrite(encrypted, to: resourceDirectory(ticket.id).appendingPathComponent(filename))
            return filename
        }
    }
    func manifest(_ ticket: MediaResourceTicket) async throws -> MediaManifest {
        try await io {
            guard let name = ticket.state.manifest, name.hasSuffix(".manifest"), UUID(uuidString: String(name.dropLast(9))) != nil else { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
            let directory = root.appendingPathComponent(ticket.id.uuidString.lowercased())
            try Self.checkDirectory(root); try Self.checkDirectory(directory)
            do {
                let cipher = try Self.readRegular(directory.appendingPathComponent(name), max: 128 * 1024)
                let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: SymmetricKey(data: ticket.key), authenticating: aad(ticket, purpose: "manifest", index: 0, bytes: ticket.state.bytes))
                let result = try JSONDecoder().decode(MediaManifest.self, from: bytes)
                guard result.version == 1, result.bytes == ticket.state.bytes, result.sha256 == ticket.state.sha256,
                      result.chunks.count == Int((result.bytes + Int64(MediaLimits.chunk) - 1) / Int64(MediaLimits.chunk)) else { throw ConfigurationError.invalidCiphertext }
                for (index, chunk) in result.chunks.enumerated() {
                    guard chunk.index == index, chunk.bytes == min(MediaLimits.chunk, Int(result.bytes) - index * MediaLimits.chunk) else { throw ConfigurationError.invalidCiphertext }
                }
                return result
            } catch { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
        }
    }
    func discard(_ chunk: MediaChunk, ticket: MediaResourceTicket) async throws {
        try await io {
            guard chunk.filename.hasSuffix(".bin"), UUID(uuidString: String(chunk.filename.dropLast(4))) != nil else { throw APIError(.internalServerError, "MEDIA_INTEGRITY_FAILED") }
            let directory = root.appendingPathComponent(ticket.id.uuidString.lowercased())
            try Self.checkDirectory(directory)
            let url = directory.appendingPathComponent(chunk.filename)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }
    func remove(_ resource: UUID) async throws {
        try await io {
            try Self.checkDirectory(root)
            let url = root.appendingPathComponent(resource.uuidString.lowercased())
            if FileManager.default.fileExists(atPath: url.path) { try Self.checkDirectory(url); try FileManager.default.removeItem(at: url) }
        }
    }
    func availableBytes() async throws -> Int64 {
        try await io {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
            return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
    }
}
