import Foundation
import CryptoKit
import Testing
@testable import AzureFish

@Suite("头像加密缓存", .serialized)
@MainActor
struct AccountAvatarCacheTests {
    @Test func identityIsolationAndMissingKeyDoNotReplaceData() throws {
        let keys = MemorySecureValues(), user = UUID(), peer = UUID(), asset = UUID().uuidString
        let cache = AccountAvatarCache(keys: keys, environment: "test", user: user)
        defer { try? cache.delete() }
        let bytes = Data("fictional-avatar".utf8)
        try cache.save(bytes, user: peer, asset: asset)
        #expect(try cache.load(user: peer, asset: asset) == bytes)
        #expect(try cache.load(user: UUID(), asset: asset) == nil)
        #expect(try cache.load(user: peer, asset: "other") == nil)
        let other = AccountAvatarCache(keys: keys, environment: "test", user: UUID())
        #expect(try other.load(user: peer, asset: asset) == nil)
        let retained = keys.data
        keys.data.removeAll()
        #expect(throws: AccountFailure.missingKey) { try cache.load(user: peer, asset: asset) }
        #expect(throws: AccountFailure.missingKey) { try cache.save(bytes, user: peer, asset: asset) }
        #expect(keys.data.isEmpty)
        keys.data = retained
        #expect(try cache.load(user: peer, asset: asset) == bytes)
    }
    @Test func deletionRemovesCacheBeforeKey() throws {
        let keys = MemorySecureValues(), user = UUID(), asset = UUID().uuidString
        let cache = AccountAvatarCache(keys: keys, environment: "test", user: user)
        try cache.save(Data("image".utf8), user: user, asset: asset)
        try cache.delete()
        #expect(keys.data.isEmpty)
        #expect(try cache.load(user: user, asset: asset) == nil)
    }
    @Test func wrongKeyAndTamperedCiphertextAreRejected() throws {
        let keys = MemorySecureValues(), user = UUID(), asset = UUID().uuidString
        let cache = AccountAvatarCache(keys: keys, environment: "tamper-test", user: user)
        defer { try? cache.delete() }
        try cache.save(Data("fictional-image".utf8), user: user, asset: asset)
        let original = keys.data
        for key in keys.data.keys { keys.data[key] = Data(repeating: 0, count: 32) }
        #expect(throws: (any Error).self) { try cache.load(user: user, asset: asset) }
        keys.data = original
        func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AccountAvatars/" + hash("tamper-test:" + user.uuidString.lowercased()))
        let file = root.appendingPathComponent(hash(user.uuidString + ":" + asset))
        var bytes = try Data(contentsOf: file); bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        #expect(throws: (any Error).self) { try cache.load(user: user, asset: asset) }
        #expect(keys.data == original)
    }
}
