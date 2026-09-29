import Foundation
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite("头像共享加载与失效", .serialized)
struct AccountAvatarLoaderTests {
    private func jpeg(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).jpegData(withCompressionQuality: 0.9) { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }
    @Test func concurrentConsumersShareDownloadAndMemoryThenRecoverFromDisk() async throws {
        let cache = AccountAvatarCache(keys: MemorySecureValues(), environment: "loader-test", user: UUID())
        defer { try? cache.delete() }
        let loader = AccountAvatarLoader(cache: cache)
        let resource = AccountAvatarLoader.Resource(user: UUID(), asset: "v1")
        let bytes = jpeg(.red)
        var downloads = 0
        var release: CheckedContinuation<Data?, Never>?
        let first = Task { try await loader.image(resource) {
            downloads += 1
            return await withCheckedContinuation { release = $0 }
        } }
        while release == nil { await Task.yield() }
        var joined = false
        let second = Task { joined = true; return try await loader.image(resource) { downloads += 1; return bytes } }
        while !joined { await Task.yield() }
        release?.resume(returning: bytes)
        let a = try #require(try await first.value), b = try #require(try await second.value)
        #expect(a === b && downloads == 1)
        #expect(loader.cached(resource) === a)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(loader.memoryCost == 0 && loader.cached(resource) == nil)
        let restored = try await loader.image(resource) { downloads += 1; return nil }
        #expect(restored != nil && downloads == 1)
        #expect(try cache.load(user: resource.user, asset: resource.asset) == bytes)
    }
    @Test func memoryEvictionRetainsAllDiskVersionsAndScopeIsSharedOnlyWithinAccount() async throws {
        let keys = MemorySecureValues(), owner = UUID(), peer = UUID()
        let cache = AccountAvatarCache(keys: keys, environment: "retention-test", user: owner)
        defer { try? cache.delete() }
        let loader = AccountAvatarLoader(cache: cache, budget: 1024)
        let old = AccountAvatarLoader.Resource(user: peer, asset: "old")
        let new = AccountAvatarLoader.Resource(user: peer, asset: "new")
        let red = jpeg(.red), blue = jpeg(.blue)
        _ = try await loader.image(old) { red }
        _ = try await loader.image(new) { blue }
        #expect(loader.memoryCost <= 1024)
        #expect(loader.cached(old) == nil)
        #expect(try cache.load(user: peer, asset: "old") == red)
        #expect(try cache.load(user: peer, asset: "new") == blue)
        let scope = AccountAvatarLoader.Scope(environment: "retention-test", user: owner)
        let shared = try AccountAvatarLoader.shared(scope: scope, keys: keys)
        #expect(try AccountAvatarLoader.shared(scope: scope, keys: keys) === shared)
        let otherScope = AccountAvatarLoader.Scope(environment: "retention-test-other", user: owner)
        #expect(try AccountAvatarLoader.shared(scope: otherScope, keys: keys) !== shared)
        await AccountAvatarLoader.invalidate(scope: scope)?.value
        await AccountAvatarLoader.invalidate(scope: otherScope)?.value
        let returned = try AccountAvatarLoader.shared(scope: scope, keys: keys)
        let image = try await returned.image(new) { Issue.record("登录后应复用密文"); return nil }
        #expect(image != nil)
        await AccountAvatarLoader.invalidate(scope: scope)?.value
    }
    @Test func invalidationWaitsForLateFetchAndNeverRecreatesDeletedCache() async throws {
        let cache = AccountAvatarCache(keys: MemorySecureValues(), environment: "invalidation-test", user: UUID())
        defer { try? cache.delete() }
        let loader = AccountAvatarLoader(cache: cache)
        let resource = AccountAvatarLoader.Resource(user: UUID(), asset: "late")
        var release: CheckedContinuation<Data?, Never>?
        let request = Task { try await loader.image(resource) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        let drain = loader.invalidate()
        release?.resume(returning: jpeg(.red))
        await drain.value
        await #expect(throws: CancellationError.self) { try await request.value }
        try cache.delete()
        #expect(loader.cached(resource) == nil)
        #expect(try cache.load(user: resource.user, asset: resource.asset) == nil)
    }
    @Test func cancelledConsumerDoesNotCancelOtherConsumers() async throws {
        let cache = AccountAvatarCache(keys: MemorySecureValues(), environment: "consumer-test", user: UUID())
        defer { try? cache.delete() }
        let loader = AccountAvatarLoader(cache: cache)
        let resource = AccountAvatarLoader.Resource(user: UUID(), asset: "shared")
        var release: CheckedContinuation<Data?, Never>?
        let first = Task { try await loader.image(resource) { await withCheckedContinuation { release = $0 } } }
        while release == nil { await Task.yield() }
        first.cancel()
        var joined = false
        let second = Task { joined = true; return try await loader.image(resource) { Issue.record("不得重复下载"); return nil } }
        while !joined { await Task.yield() }
        release?.resume(returning: jpeg(.blue))
        #expect(try await second.value != nil)
        await #expect(throws: CancellationError.self) { try await first.value }
    }
    @Test func missingKeyCannotBecomeNetworkMiss() async throws {
        let keys = MemorySecureValues()
        let cache = AccountAvatarCache(keys: keys, environment: "missing-test", user: UUID())
        let resource = AccountAvatarLoader.Resource(user: UUID(), asset: "v1")
        try cache.save(jpeg(.red), user: resource.user, asset: resource.asset)
        let savedKeys = keys.data
        defer { keys.data = savedKeys; try? cache.delete() }
        keys.data.removeAll()
        let loader = AccountAvatarLoader(cache: cache)
        await #expect(throws: AccountFailure.missingKey) {
            try await loader.image(resource) { Issue.record("密钥错误不能下载覆盖"); return nil }
        }
        await #expect(throws: AccountFailure.missingKey) {
            try await loader.image(.init(user: resource.user, asset: "not-yet-downloaded")) {
                Issue.record("已有目录缺钥时不得下载新资源"); return nil
            }
        }
        #expect(keys.data.isEmpty)
    }
}
