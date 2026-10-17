import Foundation
import UIKit

extension Notification.Name {
    static let accountAvatarsInvalidated = Notification.Name("AzureFish.accountAvatarsInvalidated")
}

/// 同一登录账号的窗口共享头像任务和解码图片；磁盘密文不参与内存淘汰。
@MainActor
final class AccountAvatarLoader {
    struct Scope: Hashable, Sendable {
        let environment: String
        let user: UUID
    }
    struct Resource: Hashable, Sendable {
        let user: UUID
        let asset: String
    }
    private static var sharedLoaders: [Scope: AccountAvatarLoader] = [:]
    private static var drains: [Scope: Task<Void, Never>] = [:]
    static func shared(scope: Scope, keys: any SecureValueStoring) throws -> AccountAvatarLoader {
        guard drains[scope] == nil else { throw CancellationError() }
        if let loader = sharedLoaders[scope] { return loader }
        let loader = AccountAvatarLoader(cache: AccountAvatarCache(keys: keys, environment: scope.environment, user: scope.user))
        sharedLoaders[scope] = loader
        return loader
    }
    /// 立即废弃任务和内存，返回等待所有磁盘访问结束的屏障；可重复调用。
    @discardableResult
    static func invalidate(scope: Scope) -> Task<Void, Never>? {
        if let drain = drains[scope] { return drain }
        guard let loader = sharedLoaders.removeValue(forKey: scope) else { return nil }
        let drain = loader.invalidate()
        drains[scope] = Task {
            await drain.value
            drains[scope] = nil
        }
        NotificationCenter.default.post(name: .accountAvatarsInvalidated, object: nil, userInfo: ["scope": scope])
        return drains[scope]
    }

    private let cache: AccountAvatarCache
    private let budget: Int
    private var images: [Resource: UIImage] = [:]
    private var recency: [Resource] = []
    private(set) var memoryCost = 0
    private var tasks: [Resource: Task<UIImage?, Error>] = [:]
    private var valid = true
    private var memoryWarning: NSObjectProtocol?
    init(cache: AccountAvatarCache, budget: Int = 16 * 1024 * 1024) {
        self.cache = cache; self.budget = budget
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearMemory() }
            }
    }
    func cached(_ resource: Resource) -> UIImage? {
        guard valid, let image = images[resource] else { return nil }
        recency.removeAll { $0 == resource }; recency.append(resource)
        return image
    }
    /// 消费者取消不取消共享工作；账号失效才取消任务，并在每次异步边界拒绝迟到结果。
    func image(_ resource: Resource, fetch: @escaping @MainActor @Sendable () async throws -> Data?) async throws -> UIImage? {
        try check()
        if let image = cached(resource) { return image }
        if let task = tasks[resource] {
            let image = try await task.value
            try check()
            return image
        }
        let task = Task { [self] () throws -> UIImage? in
            let local = try await cache.loadInBackground(user: resource.user, asset: resource.asset)
            try check()
            let bytes: Data
            if let local { bytes = local }
            else {
                guard let downloaded = try await fetch() else { try check(); return nil }
                try check()
                try await cache.saveInBackground(downloaded, user: resource.user, asset: resource.asset)
                try check()
                bytes = downloaded
            }
            let decoded = await Task.detached { UIImage(data: bytes)?.preparingForDisplay() }.value
            try check()
            guard let decoded else { throw AccountFailure.storage }
            insert(decoded, resource: resource)
            return decoded
        }
        tasks[resource] = task
        defer { tasks[resource] = nil }
        let image = try await task.value
        try check()
        return image
    }
    private func check() throws {
        try Task.checkCancellation()
        guard valid else { throw CancellationError() }
    }
    private func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return budget + 1 }
        return cg.bytesPerRow * cg.height
    }
    private func insert(_ image: UIImage, resource: Resource) {
        let size = cost(image)
        guard size <= budget else { return }
        while memoryCost + size > budget, let oldest = recency.first {
            recency.removeFirst()
            if let old = images.removeValue(forKey: oldest) { memoryCost -= cost(old) }
        }
        images[resource] = image; recency.append(resource); memoryCost += size
    }
    func clearMemory() { images.removeAll(); recency.removeAll(); memoryCost = 0 }
    @discardableResult
    func invalidate() -> Task<Void, Never> {
        valid = false; clearMemory()
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        return Task { for task in pending { _ = try? await task.value } }
    }
    isolated deinit { if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) } }
}
