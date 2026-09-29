import CryptoKit
import Foundation

/// 安装内按环境和登录账号隔离的头像缓存；资源与用途参与认证加密。
@MainActor
final class AccountAvatarCache {
    private let keys: any SecureValueStoring
    private let root: URL
    private let scope: String
    init(keys: any SecureValueStoring, environment: String, user: UUID) {
        self.keys = keys
        scope = environment + ":" + user.uuidString.lowercased()
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountAvatars/" + Self.hash(scope), isDirectory: true)
    }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private var keyName: String { "avatar-key." + Self.hash(scope) }
    private func key() throws -> SymmetricKey {
        if let bytes = try keys.read(keyName) {
            guard bytes.count == 32 else { throw AccountFailure.missingKey }
            return SymmetricKey(data: bytes)
        }
        guard !FileManager.default.fileExists(atPath: root.path) else { throw AccountFailure.missingKey }
        let key = SymmetricKey(size: .bits256)
        try keys.write(key.withUnsafeBytes { Data($0) }, key: keyName)
        return key
    }
    private func identity(_ user: UUID, _ asset: String) -> Data { Data((scope + ":avatar:" + user.uuidString.lowercased() + ":" + asset).utf8) }
    private func file(_ user: UUID, _ asset: String) -> URL { root.appendingPathComponent(Self.hash(user.uuidString + ":" + asset)) }
    func load(user: UUID, asset: String) throws -> Data? {
        let url = file(user, asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key(), authenticating: identity(user, asset))
    }
    func save(_ bytes: Data, user: UUID, asset: String) throws {
        let sealed = try AES.GCM.seal(bytes, using: key(), authenticating: identity(user, asset))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = root; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try directory.setResourceValues(attributes)
        try sealed.combined!.write(to: file(user, asset), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    /// Keychain 访问留在主 actor，文件读取及认证解密在后台执行；认证失败原样抛出。
    func loadInBackground(user: UUID, asset: String) async throws -> Data? {
        let url = file(user, asset)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // 已有账号目录缺钥时，即使请求的是新资源也不能当作普通未命中。
            if FileManager.default.fileExists(atPath: root.path) { _ = try key() }
            return nil
        }
        let key = try key(), identity = identity(user, asset)
        return try await Task.detached {
            try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key, authenticating: identity)
        }.value
    }
    /// 等待密文原子写入完成。账号清理必须先等待加载服务停止，再删除目录与密钥。
    func saveInBackground(_ bytes: Data, user: UUID, asset: String) async throws {
        let key = try key(), identity = identity(user, asset), url = file(user, asset), root = root
        try Task.checkCancellation()
        try await Task.detached {
            let sealed = try AES.GCM.seal(bytes, using: key, authenticating: identity)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var directory = root; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try sealed.combined!.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }.value
    }
    func deleteFiles() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    func deleteKey() throws { try keys.remove(keyName) }
    func delete() throws { try deleteFiles(); try deleteKey() }
}
