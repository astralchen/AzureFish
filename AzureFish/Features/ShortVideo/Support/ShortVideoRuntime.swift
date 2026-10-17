import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import CryptoKit
import Foundation

/// 当前窗口的短视频请求与临时媒体所有者；账号停止屏障等待下载及清理结束。
@MainActor
final class ShortVideoRuntime {
    weak var chat: ChatRuntime?
    #if DEBUG
    var fixtureAPI: (any ShortVideoServing)?
    var fixtureMoments: MomentsRuntime?
    var fixtureMedia: (@Sendable (ShortVideoItem, Bool) async throws -> Data)?
    #endif
    private var mediaContext: MomentsRuntime? {
        #if DEBUG
        if let fixtureMoments { return fixtureMoments }
        #endif
        return chat?.moments
    }
    var api: (any ShortVideoServing)? {
        guard !stopped else { return nil }
        #if DEBUG
        if let fixtureAPI { return fixtureAPI }
        #endif
        guard let chat, !chat.session.readOnly, let manager = chat.session.sessionManager else { return nil }
        return ShortVideoAPI(session: manager)
    }
    var userID: String { mediaContext?.userID ?? "" }
    private(set) var epoch = UUID()
    private var stopped = false
    func start() { stopped = false; epoch = UUID() }
    private var tasks: [UUID: (cancel: () -> Void, wait: Task<Void, Never>)] = [:]
    private var resources: [UUID: (EncryptedMediaStore, MomentsStore)] = [:]
    private var cleanups: [UUID: Task<Void, Never>] = [:]
    private var leases: [UUID: URL] = [:]
    private var observers: [UUID: () -> Void] = [:]
    init(chat: ChatRuntime? = nil) { self.chat = chat }
    @discardableResult func observeStop(_ body: @escaping () -> Void) -> UUID { let id = UUID(); observers[id] = body; return id }
    func remove(_ id: UUID) { observers[id] = nil }
    func work<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        guard !stopped else { throw CancellationError() }
        guard mediaContext?.ready == true else { throw APIClientError.invalidRequest }
        let id = UUID(), identity = epoch
        let task = Task {
            try Task.checkCancellation()
            guard !stopped, epoch == identity else { throw CancellationError() }
            return try await body()
        }
        tasks[id] = ({ task.cancel() }, Task { _ = try? await task.value })
        defer { tasks[id] = nil }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard epoch == identity else { throw CancellationError() }
        return result
    }
    /// 仅下载当前素材，先在内存中校验长度，再分块写入账号加密存储。
    func media(_ item: ShortVideoItem, thumbnail: Bool) async throws -> (UUID, URL) {
        guard let media = mediaContext?.media, let store = mediaContext?.store else { throw MediaStorageError.unavailable }
        let identity = epoch, id = UUID()
        let limit = thumbnail ? 4 * 1024 * 1024 : 50 * 1024 * 1024
        guard thumbnail || (item.bytes > 0 && item.bytes <= Int64(limit)) else { throw MediaStorageError.invalidResource }
        let text = thumbnail ? item.thumbnailURL : item.videoURL
        let bytes: Data
        #if DEBUG
        if let fixtureMedia { bytes = try await fixtureMedia(item, thumbnail) }
        else { bytes = try await ShortVideoDownload.fetch(text, limit: limit) }
        #else
        bytes = try await ShortVideoDownload.fetch(text, limit: limit)
        #endif
        guard bytes.count <= limit else { throw MediaStorageError.invalidResource }
        try Task.checkCancellation()
        guard epoch == identity, thumbnail || bytes.count == item.bytes else { throw MediaStorageError.invalidResource }
        try await store.reserve(id)
        resources[id] = (media, store)
        do {
            let input = MediaResourceDescriptor(role: thumbnail ? "short-video-cover" : "short-video", filename: thumbnail ? "cover.jpg" : "video.mp4",
                mime: thumbnail ? "image/jpeg" : "video/mp4", bytes: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            try await media.prepare(id: id, input: input)
            for offset in stride(from: 0, to: bytes.count, by: EncryptedMediaStore.chunkBytes) {
                try Task.checkCancellation()
                try await media.write(Data(bytes[offset..<min(bytes.count, offset + EncryptedMediaStore.chunkBytes)]), id: id, index: offset / EncryptedMediaStore.chunkBytes)
            }
            try await media.verify(id)
            try Task.checkCancellation()
            let url = try await media.lease(id)
            leases[id] = url
            guard identity == epoch, !Task.isCancelled else { throw CancellationError() }
            return (id, url)
        } catch { await release(id); throw error }
    }
    /// 先归还明文租约，再释放导入预留并清理加密资源；失败记录留给存储恢复。
    func release(_ id: UUID) async {
        if let task = cleanups[id] { await task.value; return }
        guard let (media, store) = resources.removeValue(forKey: id) else { return }
        let url = leases.removeValue(forKey: id)
        let task = Task {
            if let url { try? await media.release(url) }
            try? await store.finishImport(id)
            try? await store.releaseResource(id, media: media)
        }
        cleanups[id] = task
        await task.value
        cleanups[id] = nil
    }
    /// 同步通知播放器停止；返回的屏障必须先于共享朋友圈存储关闭完成。
    func stop() -> Task<Void, Never> {
        stopped = true; epoch = UUID()
        for body in Array(observers.values) { body() }
        let pending = Array(tasks.values); pending.forEach { $0.cancel() }; tasks = [:]
        return Task { [self] in
            for task in pending { await task.wait.value }
            for id in Array(resources.keys) { await release(id) }
            for task in Array(cleanups.values) { await task.value }
        }
    }
}

/// 无磁盘缓存的有界 HTTPS 下载；不携带业务会话，重定向再次验证内容域。
private final class ShortVideoDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    init(limit: Int) { self.limit = limit }
    static func valid(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "cdn.pixabay.com" && url.user == nil && url.password == nil && url.port == nil
    }
    static func fetch(_ text: String, limit: Int) async throws -> Data {
        guard let url = URL(string: text), valid(url) else { throw MediaStorageError.invalidResource }
        let download = ShortVideoDownload(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in download.start(url, continuation: continuation) }
        } onCancel: { download.cancel() }
    }
    private func start(_ url: URL, continuation: CheckedContinuation<Data, Error>) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        lock.lock()
        self.continuation = continuation
        let task = session.dataTask(with: url); self.task = task
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { task.cancel() }
        task.resume()
        session.finishTasksAndInvalidate()
    }
    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.valid) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let valid = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= limit && response.url.map(Self.valid) == true
        completionHandler(valid ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let overflow = data.count > limit - bytes.count
        if !overflow { bytes.append(data) }
        lock.unlock()
        if overflow { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = continuation, result = bytes, wasCancelled = cancelled
        self.continuation = nil; bytes = Data(); self.task = nil
        lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error { continuation?.resume(throwing: error) }
        else if result.isEmpty { continuation?.resume(throwing: MediaStorageError.invalidResource) }
        else { continuation?.resume(returning: result) }
    }
}

func shortVideoErrorKey(_ error: any Error) -> String {
    if case APIClientError.service(let failure) = error {
        switch failure.code.rawValue {
        case "SHORT_VIDEO_SOURCE_UNCONFIGURED": return "shortVideo.unconfigured"
        case "SHORT_VIDEO_SOURCE_LIMITED", "RATE_LIMITED": return "shortVideo.limited"
        case "SHORT_VIDEO_UNAVAILABLE": return "shortVideo.unavailable"
        case "VALIDATION_FAILED": return "shortVideo.invalidComment"
        case "SHORT_VIDEO_INTERACTION_LIMIT": return "shortVideo.interactionLimit"
        default: break
        }
    }
    return "shortVideo.failed"
}
