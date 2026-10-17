import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import CryptoKit
import Foundation
import UIKit

/// 每个窗口的朋友圈业务状态与账号任务；账号资源由 ChatRuntime 的统一停止屏障托管。
@MainActor
final class MomentsRuntime {
    weak var chat: ChatRuntime?
    private(set) var store: MomentsStore?
    private(set) var media: EncryptedMediaStore?
    var posts: [MomentsPost] = []
    var albums: [String: MomentsAlbum] = [:]
    var drafts: [MomentsDraft] = []
    var pending: [MomentsPendingAction] = []
    var failure: String?
    var loading = false
    /// 正在续页的作者 ID；nil 表示没有续页请求，空字符串代表主动态流。
    var loadingPageAuthor: String?
    var pageFailures: [String: String] = [:]
    /// 当前请求结束后补做的刷新范围；并发刷新仅保留最后一次请求。
    var requestedAuthor: String?
    var cursors: [String: String] = [:]
    var more: [String: Bool] = [:]
    private var observers: [UUID: () -> Void] = [:]
    private var tasks: [UUID: (cancel: () -> Void, wait: Task<Void, Never>)] = [:]
    /// 账号资源的生命周期身份；挂载或停止时替换，用于拒绝跨生命周期结果。
    var epoch = UUID()
    /// 刷新结果有效性标记；写入或好友关系变更后使旧读取结果失效。
    var refreshVersion = UUID()
    var lastOffline: Bool?
    var contactSignature: [String: Int64] = [:]
    private var chatObservation: UUID?
    private var foregroundObservation: (any NSObjectProtocol)?
    private var leasedDrafts: Set<UUID> = []
    /// 当前进程各窗口占用的草稿，按环境和账号隔离；不作为持久化锁。
    private static var editingDrafts: [String: Set<UUID>] = [:]
    private var draftScope: String { (session?.store.environmentID ?? "preview") + ":" + userID }
    var session: SessionCoordinator? { chat?.session }
    var userID: String { chat?.userID ?? previewUser }
    var offline: Bool { session?.readOnly ?? true }
    var ready: Bool { store != nil }
    private struct Thumbnail {
        let asset: ChatAsset
        let target: String
        let cover: Bool
        let image: UIImage
        let cost: Int
    }
    // 只缓存列表缩略图；账号退出和引用失效同步清除，不持久化明文。
    private var thumbnails: [Thumbnail] = []
    let photoCache = MomentsPhotoCache()
    var previewUser = ""
    var api: MomentsAPI? { guard !offline, let manager = session?.sessionManager else { return nil }; return MomentsAPI(session: manager) }
    init(chat: ChatRuntime) { self.chat = chat }
    #if DEBUG
    var previewPagination: MomentsPaginationState?
    init(preview: [MomentsPost], user: String, albums: [MomentsAlbum] = []) {
        posts = preview; previewUser = user; self.albums = Dictionary(uniqueKeysWithValues: albums.map { ($0.owner.id, $0) })
    }
    #endif
    /// 挂载账号存储并开始观察和恢复；调用方须在重新挂载前完成上一轮停止。
    func attach(database: AccountDatabase, media: EncryptedMediaStore) throws {
        store = try MomentsStore(database: database); self.media = media; epoch = UUID(); thumbnails = []; photoCache.removeAll()
        foregroundObservation = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.launch { [weak self] in try await self?.refresh() } }
        }
        chatObservation = chat?.observe { [weak self] in self?.contactsChanged() }
        launch { [weak self] in try await self?.restore(); try await self?.refresh() }
    }
    /// 注册主线程观察者并立即同步调用一次；调用方以返回的 ID 移除观察。
    @discardableResult func observe(_ body: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = body; body(); return id }
    func remove(_ id: UUID) { observers[id] = nil }
    /// 先清除失去引用的内存图片，再同步通知当前观察者。
    func notify() {
        thumbnails.removeAll { !referencesImage($0.asset, target: $0.target, cover: $0.cover) }
        photoCache.removeUnreferenced { referencesImage($0, target: $1, cover: false) }
        for body in Array(observers.values) { body() }
    }
    /// 检查完整资产描述是否仍被当前动态或相册引用，资源替换后旧描述不再匹配。
    func referencesImage(_ asset: ChatAsset, target: String, cover: Bool) -> Bool {
        cover ? albums[target]?.cover == asset : posts.contains { $0.id == target && ($0.images.contains(asset) || $0.video == asset) }
    }
    /// 同步读取当前仍可见的列表图片，命中时不经过占位图或异步解密。
    func cachedThumbnail(_ asset: ChatAsset, target: String, cover: Bool = false) -> UIImage? {
        guard referencesImage(asset, target: target, cover: cover),
              let index = thumbnails.firstIndex(where: { $0.target == target && $0.cover == cover && $0.asset == asset }) else { return nil }
        let value = thumbnails.remove(at: index); thumbnails.append(value)
        return value.image
    }
    /// 保存最多 36 张、总解码成本最多 32 MiB 的最近使用缩略图。
    func cacheThumbnail(_ image: UIImage, asset: ChatAsset, target: String, cover: Bool = false) {
        guard referencesImage(asset, target: target, cover: cover) else { return }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        let limit = 32 * 1024 * 1024
        guard cost <= limit else { return }
        thumbnails.removeAll { $0.target == target && $0.cover == cover && $0.asset.id == asset.id }
        thumbnails.append(Thumbnail(asset: asset, target: target, cover: cover, image: image, cost: cost))
        var total = thumbnails.reduce(0) { $0 + $1.cost }
        while thumbnails.count > 36 || total > limit { total -= thumbnails.removeFirst().cost }
    }
    func visible(author: String) -> [MomentsPost] { posts.filter { author.isEmpty || $0.author.id == author } }
    func hasMore(author: String) -> Bool { more[author] ?? true }
    func pageFailure(author: String) -> String? { pageFailures[author] }
    /// 首次刷新取得游标后才允许续页；失败后由用户明确重试。
    func canLoadNextPage(author: String, retry: Bool = false) -> Bool {
        ready && !offline && !loading && cursors[author] != nil && hasMore(author: author)
            && (retry || pageFailures[author] == nil)
    }
    /// 返回尚未被本进程任一窗口占用的当前账号草稿。
    func availableDrafts() -> [MomentsDraft] { drafts.filter { !(Self.editingDrafts[draftScope] ?? []).contains($0.id) } }
    /// 尝试独占编辑草稿；成功后须在页面结束时调用 release 归还占用。
    func claim(_ draft: MomentsDraft) -> Bool {
        guard Self.editingDrafts[draftScope, default: []].insert(draft.id).inserted else { return false }
        leasedDrafts.insert(draft.id); return true
    }
    func release(_ id: UUID) { leasedDrafts.remove(id); Self.editingDrafts[draftScope]?.remove(id) }
    /// 发起受账号停止屏障管理的任务；忽略取消，并将其他错误转换为页面状态。
    func launch(_ body: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do { try await self?.work(body) }
            catch is CancellationError {}
            catch { self?.failure = momentsErrorKey(error); self?.notify() }
        }
    }
    /// 登记任务并传播取消，在返回结果前核对账号生命周期身份。
    ///
    /// body 仍须在异步等待后检查取消或身份；停止屏障等待任务退出，不回滚已完成的写入。
    func work<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let identity = epoch, id = UUID()
        #if DEBUG
        if !previewUser.isEmpty { return try await body() }
        #endif
        guard store != nil else { throw AccountStorageError.unavailable }
        let task = Task { try Task.checkCancellation(); return try await body() }
        tasks[id] = ({ task.cancel() }, Task { _ = try? await task.value })
        defer { tasks[id] = nil }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard identity == epoch else { throw CancellationError() }
        return value
    }
    /// 同步撤销观察、清空可见状态并取消任务，返回等待任务结束和存储关闭的屏障。
    ///
    /// 调用方必须等待返回任务完成后再关闭共享数据库和媒体存储。
    /// - Parameter dependency: 共享存储的其他使用者的停止屏障；完成前不关闭本运行时的 store。
    func stop(after dependency: Task<Void, Never>? = nil) -> Task<Void, Never> {
        epoch = UUID(); refreshVersion = UUID(); thumbnails = []; photoCache.removeAll()
        if let foregroundObservation { NotificationCenter.default.removeObserver(foregroundObservation) }; foregroundObservation = nil
        if let chatObservation { chat?.remove(chatObservation) }; chatObservation = nil
        let pendingTasks = Array(tasks.values); pendingTasks.forEach { $0.cancel() }; tasks = [:]
        for id in leasedDrafts { Self.editingDrafts[draftScope]?.remove(id) }
        let old = store; store = nil; media = nil; posts = []; albums = [:]; drafts = []; pending = []; leasedDrafts = []
        cursors = [:]; more = [:]; pageFailures = [:]; loadingPageAuthor = nil; requestedAuthor = nil; loading = false; failure = nil; notify()
        return Task { for task in pendingTasks { await task.wait.value }; await dependency?.value; await old?.close() }
    }
    func broadcast() { NotificationCenter.default.post(name: .momentsChanged, object: self, userInfo: ["user": userID]) }
}
extension Notification.Name { static let momentsChanged = Notification.Name("AzureFish.momentsChanged") }
