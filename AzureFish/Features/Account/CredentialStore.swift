import Foundation
import Security
import AzureFishAPI

/// 可注入的受保护数据存储。写入替换整个值，失败时不删除原项。
@MainActor
protocol SecureValueStoring {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}

/// 将会话、安装身份、撤销队列和缓存密钥存入彼此独立的 Keychain 项。
@MainActor
final class KeychainValueStore: SecureValueStoring {
    private let service = "com.azurefish.account.v1"
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccountFailure.storage }
        return data
    }
    func write(_ data: Data, key: String) throws {
        let query = query(key)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            attributes.forEach { new[$0.key] = $0.value }
            guard SecItemAdd(new as CFDictionary, nil) == errSecSuccess else { throw AccountFailure.storage }
        } else if status != errSecSuccess { throw AccountFailure.storage }
    }
    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountFailure.storage }
    }
}

/// 一个原子 Keychain 认证包；pending ID 与旧代凭据共同提交。
struct StoredSession: Codable, Sendable, CustomStringConvertible {
    var environmentID: String
    var userID: UUID
    var deviceID: UUID
    var sessionID: UUID
    private var accessToken: String
    private var accessExpiresAt: Date
    private var refreshToken: String
    private var refreshExpiresAt: Date
    private var refreshGeneration: Int64
    var pendingRefreshID: UUID?
    var description: String { "StoredSession(<redacted>)" }
    init(_ credentials: SessionCredentials, pendingRefreshID: UUID? = nil) {
        environmentID = credentials.environmentID; userID = credentials.userID
        deviceID = credentials.deviceID; sessionID = credentials.sessionID
        accessToken = credentials.accessToken.rawValue; accessExpiresAt = credentials.accessExpiresAt
        refreshToken = credentials.refreshToken.rawValue; refreshExpiresAt = credentials.refreshExpiresAt
        refreshGeneration = credentials.refreshGeneration; self.pendingRefreshID = pendingRefreshID
    }
    func credentials() throws -> SessionCredentials {
        try SessionCredentials(environmentID: environmentID, userID: userID, deviceID: deviceID,
            sessionID: sessionID, accessToken: SessionToken(rawValue: accessToken), accessExpiresAt: accessExpiresAt,
            refreshToken: SessionToken(rawValue: refreshToken), refreshExpiresAt: refreshExpiresAt,
            refreshGeneration: refreshGeneration)
    }
}

/// 登录页使用的账号提示，不是认证凭据，也不能授权打开账号存储。
struct RememberedLoginAccount: Codable, Equatable {
    let environmentID: String
    let userID: UUID
    let accountName: String
}

@MainActor
final class CredentialStore {
    let values: any SecureValueStoring
    let environmentID: String
    private var sessionKey: String { "session.\(environmentID)" }
    private var revocationKey: String { "revocations.\(environmentID)" }
    init(values: any SecureValueStoring, environmentID: String) {
        self.values = values; self.environmentID = environmentID
    }
    func installationID() throws -> UUID {
        if let data = try values.read("installation"), let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) { return id }
        if try values.read("installation") != nil { throw AccountFailure.storage }
        let id = UUID()
        try values.write(Data(id.uuidString.utf8), key: "installation")
        return id
    }
    func load() throws -> StoredSession? {
        guard let data = try values.read(sessionKey) else { return nil }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              stored.environmentID == environmentID, (try? stored.credentials()) != nil else { throw AccountFailure.storage }
        return stored
    }
    func save(_ value: StoredSession) throws {
        guard value.environmentID == environmentID else { throw AccountFailure.storage }
        try values.write(JSONEncoder().encode(value), key: sessionKey)
    }
    func clear() throws { try values.remove(sessionKey) }
    private var rememberedKey: String { "remembered-login." + environmentID }
    func rememberedAccount() throws -> RememberedLoginAccount? {
        guard let data = try values.read(rememberedKey) else { return nil }
        let value = try JSONDecoder().decode(RememberedLoginAccount.self, from: data)
        guard value.environmentID == environmentID else { throw AccountFailure.storage }
        return value
    }
    func remember(_ profile: AccountProfile) throws {
        let value = RememberedLoginAccount(environmentID: environmentID, userID: profile.userID, accountName: profile.accountName)
        try values.write(JSONEncoder().encode(value), key: rememberedKey)
    }
    func forgetAccount(user: UUID) throws {
        if try rememberedAccount()?.userID == user { try values.remove(rememberedKey) }
    }
    func revocations() throws -> [LogoutRevocation] {
        guard let data = try values.read(revocationKey) else { return [] }
        do { return try JSONDecoder().decode([LogoutRevocation].self, from: data) }
        catch { throw AccountFailure.storage }
    }
    func saveRevocations(_ values: [LogoutRevocation]) throws {
        if values.isEmpty { try self.values.remove(revocationKey) }
        else { try self.values.write(JSONEncoder().encode(values), key: revocationKey) }
    }
}

/// 适配已有原子 Keychain 会话包，HTTP 与实时连接共用同一份凭据。
@MainActor
final class KeychainAPISessionStore: APISessionStore {
    private let store: CredentialStore
    init(store: CredentialStore) { self.store = store }
    func load(environmentID: String) async throws -> APISessionRecord? {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        return try store.load().map { try APISessionRecord(credentials: $0.credentials(), pendingRefreshOperationID: $0.pendingRefreshID) }
    }
    func save(_ record: APISessionRecord, environmentID: String) async throws {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        try store.save(StoredSession(record.credentials, pendingRefreshID: record.pendingRefreshOperationID))
    }
    func clear(environmentID: String) async throws {
        guard environmentID == store.environmentID else { throw AccountFailure.storage }
        try store.clear()
    }
}
