import Foundation
import Testing
import AzureFishAPI
@testable import AzureFish

@MainActor
final class MemorySecureValues: SecureValueStoring {
    var data: [String: Data] = [:]
    var failWrites = false
    var onWrite: ((String) -> Void)?
    func read(_ key: String) throws -> Data? { data[key] }
    func write(_ bytes: Data, key: String) throws {
        if failWrites { throw AccountFailure.storage }
        data[key] = bytes
        onWrite?(key)
    }
    func remove(_ key: String) throws {
        if failWrites { throw AccountFailure.storage }
        data[key] = nil
    }
}

@Suite("账号输入与安全快照")
@MainActor
struct AccountStorageTests {
    @Test func rememberedAccountIsEnvironmentScopedAndSurvivesCredentialClear() throws {
        let keys = MemorySecureValues()
        let first = CredentialStore(values: keys, environmentID: "first")
        let second = CredentialStore(values: keys, environmentID: "second")
        let profile = AccountProfile(userID: UUID(), accountName: "fictional", nickname: "Not stored", bio: "Not stored", version: 1)
        try first.remember(profile)
        try first.clear()
        #expect(try first.rememberedAccount()?.userID == profile.userID)
        #expect(try second.rememberedAccount() == nil)
        let data = try #require(keys.data["remembered-login.first"])
        #expect(!String(decoding: data, as: UTF8.self).contains("Not stored"))
        keys.failWrites = true
        #expect(throws: (any Error).self) { try first.remember(.init(userID: UUID(), accountName: "another", nickname: "", bio: "", version: 1)) }
        #expect(keys.data["remembered-login.first"] == data)
        keys.failWrites = false
        try first.forgetAccount(user: UUID())
        #expect(try first.rememberedAccount() != nil)
        try first.forgetAccount(user: profile.userID)
        #expect(try first.rememberedAccount() == nil)
    }

    @Test func validationUsesCharactersAndUTF8Separately() {
        #expect(AccountValidation.account(" Fictional_USER "))
        #expect(!AccountValidation.account("用户abc"))
        #expect(!AccountValidation.account("ab"))
        #expect(AccountValidation.password(String(repeating: "鱼", count: 24)))
        #expect(!AccountValidation.password(String(repeating: "鱼", count: 25)))
        #expect(!AccountValidation.password("short"))
        #expect(!AccountValidation.password("123456789012\0"))
        #expect(AccountValidation.nickname(String(repeating: "👍🏽", count: 64)))
        #expect(!AccountValidation.nickname("👨‍👩‍👧‍👦"))
        #expect(!AccountValidation.nickname(" \n "))
        #expect(!AccountValidation.nickname("name\t"))
        #expect(AccountValidation.bio(""))
        #expect(AccountValidation.bio("line\nline"))
        #expect(!AccountValidation.bio(String(repeating: "a", count: 501)))
    }
    @Test func encryptedRoundTripTamperAndMissingKeyNeverOverwrite() throws {
        let keys = MemorySecureValues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = UserRepository(root: root, keys: keys, environment: "local-development")
        let profile = AccountProfile(userID: UUID(), accountName: "fictional", nickname: "PRIVATE-NICKNAME", bio: "private bio", version: 1)
        try repository.save(profile)
        #expect(try repository.load(user: profile.userID) == profile)
        let url = repository.fileURL(for: profile.userID)
        let original = try Data(contentsOf: url)
        #expect(!String(decoding: original, as: UTF8.self).contains("PRIVATE-NICKNAME"))
        var corrupted = original; corrupted[corrupted.count / 2] ^= 1
        try corrupted.write(to: url)
        #expect(throws: (any Error).self) { try repository.load(user: profile.userID) }
        #expect(throws: (any Error).self) { try repository.save(profile) }
        #expect(try Data(contentsOf: url) == corrupted)
        try original.write(to: url)
        keys.data.removeAll()
        #expect(throws: AccountFailure.missingKey) { try repository.save(profile) }
        #expect(try Data(contentsOf: url) == original)
        #expect(keys.data.isEmpty)
    }
    @Test func crossAccountSubstitutionAndKeyWriteFailure() throws {
        let keys = MemorySecureValues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = UserRepository(root: root, keys: keys, environment: "local-development")
        let a = AccountProfile(userID: UUID(), accountName: "a", nickname: "A", bio: "", version: 1)
        let b = AccountProfile(userID: UUID(), accountName: "b", nickname: "B", bio: "", version: 1)
        try repository.save(a); try repository.save(b)
        try Data(contentsOf: repository.fileURL(for: a.userID)).write(to: repository.fileURL(for: b.userID))
        #expect(throws: AccountFailure.damagedCache) { try repository.load(user: b.userID) }
        keys.failWrites = true
        let c = AccountProfile(userID: UUID(), accountName: "c", nickname: "C", bio: "", version: 1)
        #expect(throws: AccountFailure.storage) { try repository.save(c) }
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL(for: c.userID).path))
    }
    @Test func interruptedSnapshotReplacementKeepsOriginalReadable() throws {
        let keys = MemorySecureValues()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = UserRepository(root: root, keys: keys, environment: "local-development")
        let original = AccountProfile(userID: UUID(), accountName: "fictional", nickname: "Original", bio: "", version: 1)
        try repository.save(original)
        let bytes = try Data(contentsOf: repository.fileURL(for: original.userID))
        let interrupted = UserRepository(root: root, keys: keys, environment: "local-development", writeFile: { _, _ in throw AccountFailure.storage })
        let next = AccountProfile(userID: original.userID, accountName: original.accountName, nickname: "New", bio: "", version: 2)
        #expect(throws: AccountFailure.storage) { try interrupted.save(next) }
        #expect(try Data(contentsOf: repository.fileURL(for: original.userID)) == bytes)
        #expect(try repository.load(user: original.userID) == original)
    }

    @Test func credentialWriteFailureRetainsPreviousAtomicPackage() throws {
        let keys = MemorySecureValues()
        let store = CredentialStore(values: keys, environmentID: "local-development")
        let value = try sampleCredentials()
        try store.save(StoredSession(value))
        let before = keys.data
        keys.failWrites = true
        #expect(throws: AccountFailure.storage) { try store.save(StoredSession(value, pendingRefreshID: UUID())) }
        #expect(keys.data == before)
        #expect(try store.load()?.credentials() == value)
    }
}

func sampleCredentials(accessExpired: Bool = false) throws -> SessionCredentials {
    try SessionCredentials(environmentID: "local-development", userID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
        deviceID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!, sessionID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
        accessToken: SessionToken(rawValue: String(repeating: "a", count: 43)), accessExpiresAt: Date(timeIntervalSince1970: accessExpired ? 1 : 2_000_000_000),
        refreshToken: SessionToken(rawValue: String(repeating: "r", count: 43)), refreshExpiresAt: Date(timeIntervalSince1970: 2_002_000_000), refreshGeneration: 1)
}
