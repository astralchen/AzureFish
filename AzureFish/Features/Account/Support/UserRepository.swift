import CryptoKit
import Foundation

/// 账号隔离的 AES-GCM 资料快照。当前仅允许虚构账号开发环境启用持久化。
///
/// 缺失密钥、认证失败或格式损坏均停止访问原文件，不生成替代密钥或覆盖缓存。
@MainActor
final class UserRepository {
    private struct Envelope: Codable {
        let formatVersion: Int
        let keyID: UUID
        let nonce: Data
        let ciphertext: Data
        let tag: Data
        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version", keyID = "key_id", nonce, ciphertext, tag
        }
    }
    private struct KeyRecord: Codable { let id: UUID; let bytes: Data }
    private let root: URL
    private let keys: any SecureValueStoring
    let environment: String
    private let writeFile: (Data, URL) throws -> Void
    init(root: URL, keys: any SecureValueStoring, environment: String,
         writeFile: @escaping (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
         }) {
        self.root = root; self.keys = keys; self.environment = environment; self.writeFile = writeFile
    }
    private func identifier(_ user: UUID) -> String {
        SHA256.hash(data: Data("\(environment)/\(user.uuidString.lowercased())".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func fileURL(for user: UUID) -> URL { root.appendingPathComponent(identifier(user)).appendingPathExtension("afprofile") }
    private func key(for user: UUID, create: Bool) throws -> KeyRecord {
        let name = "profile-key.\(identifier(user))"
        if let data = try keys.read(name) {
            guard let key = try? JSONDecoder().decode(KeyRecord.self, from: data), key.bytes.count == 32 else { throw AccountFailure.missingKey }
            return key
        }
        guard create && !FileManager.default.fileExists(atPath: fileURL(for: user).path) else { throw AccountFailure.missingKey }
        let key = KeyRecord(id: UUID(), bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        try keys.write(JSONEncoder().encode(key), key: name)
        return key
    }
    private func aad(user: UUID, key: UUID) -> Data {
        var data = Data()
        for value in [environment, user.uuidString.lowercased(), "profile", "snapshot", "1", key.uuidString.lowercased()] {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }
    func load(user: UUID) throws -> AccountProfile? {
        let url = fileURL(for: user)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let key = try key(for: user, create: false)
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.formatVersion == 1, envelope.keyID == key.id,
                  envelope.nonce.count == 12, envelope.tag.count == 16 else { throw AccountFailure.damagedCache }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext, tag: envelope.tag),
                using: SymmetricKey(data: key.bytes), authenticating: aad(user: user, key: key.id))
            let profile = try JSONDecoder().decode(AccountProfile.self, from: bytes)
            guard profile.userID == user, profile.version > 0 else { throw AccountFailure.damagedCache }
            return profile
        } catch { throw AccountFailure.damagedCache }
    }
    func deleteFiles(user: UUID) throws {
        let url = fileURL(for: user)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func deleteKey(user: UUID) throws { try keys.remove("profile-key.\(identifier(user))") }
    func save(_ profile: AccountProfile) throws {
        guard environment == "local-development" else { throw AccountFailure.unavailable }
        // 先验证已有快照，损坏时保留原件并交由明确恢复流程处理。
        if let existing = try load(user: profile.userID), existing.version > profile.version { return }
        let key = try key(for: profile.userID, create: true)
        do {
            let box = try AES.GCM.seal(JSONEncoder().encode(profile), using: SymmetricKey(data: key.bytes),
                authenticating: aad(user: profile.userID, key: key.id))
            // 先验证认证加密结果，再替换磁盘上的旧快照。
            _ = try AES.GCM.open(box, using: SymmetricKey(data: key.bytes), authenticating: aad(user: profile.userID, key: key.id))
            let data = try JSONEncoder().encode(Envelope(formatVersion: 1, keyID: key.id,
                nonce: box.nonce.withUnsafeBytes { Data($0) }, ciphertext: box.ciphertext, tag: box.tag))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var directory = root
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            try directory.setResourceValues(excluded)
            try writeFile(data, fileURL(for: profile.userID))
        } catch { throw AccountFailure.storage }
    }
}
