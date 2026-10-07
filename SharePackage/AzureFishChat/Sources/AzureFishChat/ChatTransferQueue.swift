import AzureFishAPI
import AzureFishNetwork
import Foundation

public struct ChatUploadItem: Codable, Sendable {
    /// 从持久记录恢复上传条目及全部固定操作身份，不创建新身份或执行上传。
    init(id: UUID, kind: String, resources: [ChatLocalMedia], assetID: String?, completeID: UUID, cancelID: UUID) {
        self.id = id
        self.kind = kind
        self.resources = resources
        self.assetID = assetID
        self.completeID = completeID
        self.cancelID = cancelID
    }
    /// 媒体资产创建操作的稳定 UUID，重试沿用。
    public let id: UUID
    /// 此上传条目的媒体类型原值。
    public let kind: String
    /// 条目的有序本机资源清单，文件内容由加密媒体存储持有。
    public let resources: [ChatLocalMedia]
    /// 服务端创建后返回的资产身份；nil 表示尚未记录创建结果。
    public var assetID: String?
    /// 提交媒体资产完成动作的固定幂等身份。
    public let completeID: UUID
    /// 提交媒体资产取消动作的固定幂等身份。
    public let cancelID: UUID
    /// 为一个媒体条目生成创建、完成和取消操作身份，保存资源顺序；尚无服务端资产身份。
    public init(kind: String, resources: [ChatLocalMedia]) {
        id = UUID()
        self.kind = kind
        self.resources = resources
        completeID = UUID()
        cancelID = UUID()
    }
}
public struct ChatUploadBatch: Codable, Sendable {
    /// 从持久记录恢复上传批次、发送身份和进度，保留原始创建时间。
    init(id: UUID, messageID: UUID, clientID: UUID, operationID: UUID, deviceID: UUID, createdAt: Date, conversation: String, kind: String, items: [ChatUploadItem], state: String, completedBytes: Int64, cancelRequested: Bool) {
        self.id = id
        self.messageID = messageID
        self.clientID = clientID
        self.operationID = operationID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.conversation = conversation
        self.kind = kind
        self.items = items
        self.state = state
        self.completedBytes = completedBytes
        self.cancelRequested = cancelRequested
    }
    /// 本机持久上传批次的稳定 UUID。
    public let id: UUID
    /// 所关联消息的稳定身份。
    public let messageID: UUID
    /// 客户端生成的消息去重身份；同一次发送重试保持不变。
    public let clientID: UUID
    /// 业务动作的幂等身份；恢复和重试同一动作时保持不变。
    public let operationID: UUID
    /// 发起操作的客户端安装身份，不表示硬件认证结果。
    public let deviceID: UUID
    /// 批次在本机创建的时间，用于上传工作者排序。
    public let createdAt: Date
    /// 批次最终消息所属的聊天会话身份。
    public let conversation: String
    /// 全部条目完成后提交的消息内容类型。
    public let kind: String
    /// 保留用户选择顺序的上传条目，进度更新不得替换各条目的固定身份。
    public var items: [ChatUploadItem]
    /// 批次处理状态；新建为 preparing，上传与服务端加工使用独立状态。
    public var state: String
    /// 已记录完成的上传字节数。
    public var completedBytes: Int64
    /// 是否已请求取消上传；迟到进度不能将其恢复为 false。
    public var cancelRequested: Bool
    /// 创建新上传批次及固定发送身份；初始状态为 preparing、完成字节为 0，未请求取消。
    public init(conversation: String, kind: String, items: [ChatUploadItem], deviceID: UUID) {
        id = UUID()
        messageID = UUID()
        clientID = UUID()
        operationID = UUID()
        createdAt = Date()
        self.conversation = conversation
        self.kind = kind
        self.items = items
        self.deviceID = deviceID
        state = "preparing"
        completedBytes = 0
        cancelRequested = false
    }
}
/// 持久上传任务串行执行，每次仅上传一个分块；处理和消息提交使用独立状态。
public actor ChatTransferQueue {
    /// 保存上传批次、发送顺序及资源引用的账号事务入口。
    private let store: ChatStore
    /// 提供已加密本机分块和下载缓存的媒体存储。
    private let media: ChatMediaStore
    /// 共享会话下的媒体控制及分块请求适配器。
    private let api: MediaAPI
    /// 接收上传状态通知并提交最终媒体消息的聊天引擎。
    private let engine: ChatEngine
    /// 当前串行上传处理任务；nil 表示本轮没有工作者。
    private var worker: Task<Void, Never>?
    /// 上传工作者代次，避免旧任务结束时清除新任务。
    private var generation = UUID()
    private var pausing: Task<Void, Never>?
    private var resumeRequested = false
    /// 绑定聊天存储、媒体存储、会话和引擎；不自动读取队列或启动传输。
    public init(store: ChatStore, media: ChatMediaStore, session: APISessionManager, engine: ChatEngine, transport: (any HTTPTransport)? = nil) {
        self.store = store
        self.media = media
        api = MediaAPI(session: session, transport: transport)
        self.engine = engine
    }
    /// 读取服务端能力并校验条目数及总字节数，保存上传批次后尝试启动工作者。
    public func enqueue(_ batch: ChatUploadBatch) async throws {
        let capabilities = try await api.capabilities()
        guard !batch.items.isEmpty, batch.items.count <= capabilities.groupItems else {
            throw APIClientError.invalidRequest
        }
        let total = batch.items.flatMap(\.resources).reduce(Int64(0)) { $0 + $1.input.bytes }
        guard total <= capabilities.groupBytes else { throw APIClientError.requestTooLarge }
        try await store.saveTransfer(batch)
        resume()
    }
    /// 未永久停止且没有工作者时启动一轮持久队列处理；不保证此刻已有待传数据。
    public func resume() {
        guard !stopped else { return }
        if pausing != nil { resumeRequested = true; return }
        guard worker == nil else { return }
        let id = UUID()
        generation = id
        worker = Task { await self.run(id) }
    }
    private let downloadOwner = UUID()
    /// 是否已永久停止此队列；为 true 时禁止 resume 和新的 download。
    private var stopped = false
    /// 永久禁止本实例恢复上传或接收新下载，并取消、等待当前传输任务结束。
    public func stop() async {
        stopped = true
        await pause()
    }
    /// 暂停传输而保留用户已经提交的队列；认证确认后可再次 resume。
    public func pause() async {
        if let pausing { await pausing.value; return }
        resumeRequested = false
        let previous = worker
        previous?.cancel()
        let owner = downloadOwner
        let drain = Task {
            await ChatDownloadCoordinator.shared.cancelAndDrain(owner: owner)
            await previous?.value
        }
        pausing = drain
        await drain.value
        worker = nil
        pausing = nil
        if resumeRequested { resumeRequested = false; resume() }
    }

    /// 为已有批次持久化取消意图并唤醒队列；服务端取消由工作者稍后执行，不存在时直接返回。
    public func cancel(_ id: UUID) async throws {
        guard var batch = try await store.transfers().first(where: { $0.id == id }) else {
            return
        }
        batch.cancelRequested = true
        try await store.saveTransfer(batch)
        resume()
    }
    /// 将已有批次状态重置为 preparing 并恢复队列；保留全部操作身份和取消意图。
    public func retry(_ id: UUID) async throws {
        guard var batch = try await store.transfers().first(where: { $0.id == id }) else {
            return
        }
        batch.state = "preparing"
        try await store.saveTransfer(batch)
        resume()
    }
    /// 按创建时间串行处理上传、服务端加工及消息提交，保存进度与失败状态并响应取消。
    private func run(_ id: UUID) async {
        defer { if generation == id { worker = nil } }
        do {
            for initial in try await store.transfers().sorted(by: {
                $0.createdAt < $1.createdAt
            }) where initial.state != "failed" || initial.cancelRequested {
                var batch = initial
                do {
                    for index in batch.items.indices {
                        try Task.checkCancellation()
                        let current = try await store.transfers().first { $0.id == batch.id }
                        batch.cancelRequested = current?.cancelRequested ?? batch.cancelRequested
                        if batch.cancelRequested {
                            try await cancelResources(batch)
                            break
                        }
                        var item = batch.items[index]
                        var status: ChatAssetStatus
                        if let asset = item.assetID {
                            status = try await api.status(asset)
                        } else {
                            status = try await api.create(
                                conversation: batch.conversation, kind: item.kind,
                                resources: item.resources.map(\.input), operationID: item.id)
                            item.assetID = status.id
                            batch.items[index] = item
                            try await store.saveTransfer(batch)
                        }
                        if status.state == "uploading" {
                            batch.state = "uploading"
                            for resource in item.resources {
                                guard let upload = status.uploads.first(where: { $0.role == resource.input.role })
                                else { throw APIClientError.invalidResponse }
                                for part in 0..<Int(upload.partCount) where !upload.completed.contains(Int32(part)) {
                                    try Task.checkCancellation()
                                    if try await store.transfers().first(where: {
                                        $0.id == batch.id
                                    })?.cancelRequested == true {
                                        batch.cancelRequested = true
                                        break
                                    }
                                    let bytes = try await media.read(resource.id, index: part)
                                    try await api.upload(upload.uploadID, index: part, bytes: bytes)
                                    batch.completedBytes += Int64(bytes.count)
                                    try await store.saveTransfer(batch)
                                    await engine.changed(conversation: batch.conversation, scope: [.transfers])
                                }
                            }
                            if batch.cancelRequested {
                                try await cancelResources(batch)
                                break
                            }
                            status = try await api.finish(status.id, operationID: item.completeID)
                        }
                        batch.state = "processing"
                        try await store.saveTransfer(batch)
                        await engine.changed(conversation: batch.conversation, scope: [.transfers])
                        while ["queued", "processing"].contains(status.state) {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            try Task.checkCancellation()
                            if try await store.transfers().first(where: { $0.id == batch.id })?
                                .cancelRequested == true
                            {
                                batch.cancelRequested = true
                                break
                            }
                            status = try await api.status(status.id)
                        }
                        if batch.cancelRequested {
                            try await cancelResources(batch)
                            break
                        }
                        guard status.state == "ready" else { throw ChatMediaStoreError.unavailable }
                    }
                    let latest = try await store.transfers().first(where: { $0.id == batch.id })
                    batch.cancelRequested = batch.cancelRequested || latest?.cancelRequested == true
                    if batch.cancelRequested {
                        if latest != nil { try await cancelResources(batch) }
                    } else {
                        let assets = batch.items.compactMap(\.assetID)
                        guard assets.count == batch.items.count else { throw APIClientError.invalidResponse }
                        let outgoing = ChatOutgoing(
                            conversationID: batch.conversation, deviceID: batch.deviceID, kind: batch.kind,
                            assets: assets, id: batch.messageID, clientID: batch.clientID,
                            operationID: batch.operationID)
                        try await store.submitTransfer(outgoing, transfer: batch.id)
                        await engine.changed(conversation: batch.conversation, scope: [.messages, .transfers, .conversations])
                        await engine.flush()
                    }
                } catch {
                    if error is CancellationError { throw error }
                    try Task.checkCancellation()
                    if case ChatStoreError.transferCancelled = error {
                        try await cancelResources(batch)
                        continue
                    }
                    batch.state = "waiting"
                    if case APIClientError.service(let failure) = error, (400..<500).contains(failure.statusCode),
                        failure.statusCode != 429
                    {
                        batch.state = "failed"
                    }
                    if error is ChatMediaStoreError { batch.state = "failed" }
                    try await store.saveTransfer(batch)
                    await engine.changed(conversation: batch.conversation, scope: [.transfers])
                }
            }
        } catch { if !(error is CancellationError), !Task.isCancelled { await engine.changed(scope: [.transfers]) } }
    }
    /// 依次取消已创建的服务端资产，移除批次并尝试清理不再引用的本地资源。
    private func cancelResources(_ batch: ChatUploadBatch) async throws {
        for item in batch.items {
            if let id = item.assetID { _ = try await api.finish(id, cancel: true, operationID: item.cancelID) }
        }
        try await store.removeTransfer(batch.id)
        try? await store.cleanupMedia(using: media)
        await engine.changed(conversation: batch.conversation, scope: [.transfers])
    }
    /// 逐段授权下载，重启后复用已认证分块；最终摘要通过后才允许明文租约。
    public func download(_ resource: ChatResource, message: String) async throws -> UUID {
        guard !stopped, pausing == nil else { throw CancellationError() }
        try Task.checkCancellation()
        // 每个消息引用独立授权，合并传输不共享访问权限。
        _ = try await api.authorize(resource.id, message: message)
        try Task.checkCancellation()
        guard let resourceID = UUID(uuidString: resource.id) else { throw APIClientError.invalidResponse }
        let input = ChatMediaInput(role: resource.role, filename: resource.filename, mime: resource.mime,
                                   bytes: resource.bytes, sha256: resource.sha256)
        try await media.prepare(id: resourceID, input: input)
        let key = store.environment + ":" + store.userID.uuidString + ":" + resourceID.uuidString + ":" + resource.sha256
        guard !stopped, pausing == nil else { throw CancellationError() }
        let result = try await ChatDownloadCoordinator.shared.download(key: key, owner: downloadOwner, request: UUID()) {
            try await self.performDownload(resource, message: message)
        }
        try Task.checkCancellation()
        guard !stopped, pausing == nil else { throw CancellationError() }
        _ = try await api.authorize(resource.id, message: message)
        try Task.checkCancellation()
        return result
    }
    /// 复用已登记分块，逐块重新授权下载；即使缓存完整也重新授权并校验整文件摘要。
    private func performDownload(_ resource: ChatResource, message: String) async throws -> UUID {
        guard let id = UUID(uuidString: resource.id) else { throw APIClientError.invalidResponse }
        let input = ChatMediaInput(
            role: resource.role, filename: resource.filename, mime: resource.mime, bytes: resource.bytes,
            sha256: resource.sha256)
        try await media.prepare(id: id, input: input)
        let completed = try await media.completed(id)
        let count = Int((resource.bytes + Int64(ChatMediaStore.chunkBytes) - 1) / Int64(ChatMediaStore.chunkBytes))
        for index in 0..<count where !completed.contains(index) {
            try Task.checkCancellation()
            let grant = try await api.authorize(resource.id, message: message)
            let offset = Int64(index) * Int64(ChatMediaStore.chunkBytes)
            let size = Int(min(Int64(ChatMediaStore.chunkBytes), resource.bytes - offset))
            let bytes = try await api.download(grant, offset: offset, count: size)
            try Task.checkCancellation()
            try await media.write(bytes, id: id, index: index)
        }
        // 即使全部命中缓存，也重新检查当前消息权限，撤回不能通过本机旧授权重新打开。
        _ = try await api.authorize(resource.id, message: message)
        try Task.checkCancellation()
        try await media.verify(id)
        return id
    }
    /// 请求取消上传工作者；显式 stop 负责协调等待当前上传与下载结束。
    deinit {
        worker?.cancel()
        let owner = downloadOwner
        Task { await ChatDownloadCoordinator.shared.cancelAndDrain(owner: owner) }
    }
}
