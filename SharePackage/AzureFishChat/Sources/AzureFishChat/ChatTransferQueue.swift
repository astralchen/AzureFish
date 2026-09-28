import AzureFishAPI
import Foundation

public struct ChatUploadItem: Codable, Sendable {
    public let id: UUID
    public let kind: String
    public let resources: [ChatLocalMedia]
    public var assetID: String?
    public let completeID: UUID
    public let cancelID: UUID
    public init(kind: String, resources: [ChatLocalMedia]) {
        id = UUID()
        self.kind = kind
        self.resources = resources
        completeID = UUID()
        cancelID = UUID()
    }
}
public struct ChatUploadBatch: Codable, Sendable {
    public let id: UUID
    public let messageID: UUID
    public let clientID: UUID
    public let operationID: UUID
    public let deviceID: UUID
    public let createdAt: Date
    public let conversation: String
    public let kind: String
    public var items: [ChatUploadItem]
    public var state: String
    public var completedBytes: Int64
    public var cancelRequested: Bool
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
    private let store: ChatStore
    private let media: ChatMediaStore
    private let api: MediaAPI
    private let engine: ChatEngine
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    public init(store: ChatStore, media: ChatMediaStore, session: APISessionManager, engine: ChatEngine) {
        self.store = store
        self.media = media
        api = MediaAPI(session: session)
        self.engine = engine
    }
    public func enqueue(_ batch: ChatUploadBatch) async throws {
        let capabilities = try await api.capabilities()
        guard !batch.items.isEmpty, batch.items.count <= capabilities.groupItems else {
            throw APIClientError.invalidRequest
        }
        let total = batch.items.flatMap(\.resources).reduce(Int64(0)) { $0 + $1.input.bytes }
        guard total <= capabilities.groupBytes else { throw APIClientError.requestTooLarge }
        try await store.saveTransfer(batch, id: batch.id)
        resume()
    }
    public func resume() {
        guard worker == nil else { return }
        let id = UUID()
        generation = id
        worker = Task { await self.run(id) }
    }
    public func stop() {
        generation = UUID()
        worker?.cancel()
        worker = nil
    }
    public func cancel(_ id: UUID) async throws {
        guard var batch = try await store.transfers(as: ChatUploadBatch.self).first(where: { $0.id == id }) else {
            return
        }
        batch.cancelRequested = true
        try await store.saveTransfer(batch, id: id)
        resume()
    }
    public func retry(_ id: UUID) async throws {
        guard var batch = try await store.transfers(as: ChatUploadBatch.self).first(where: { $0.id == id }) else {
            return
        }
        batch.state = "preparing"
        try await store.saveTransfer(batch, id: id)
        resume()
    }
    private func run(_ id: UUID) async {
        defer { if generation == id { worker = nil } }
        do {
            for initial in try await store.transfers(as: ChatUploadBatch.self).sorted(by: {
                $0.createdAt < $1.createdAt
            }) where initial.state != "failed" || initial.cancelRequested {
                var batch = initial
                do {
                    for index in batch.items.indices {
                        try Task.checkCancellation()
                        let current = try await store.transfers(as: ChatUploadBatch.self).first { $0.id == batch.id }
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
                            try await store.saveTransfer(batch, id: batch.id)
                        }
                        if status.state == "uploading" {
                            batch.state = "uploading"
                            for resource in item.resources {
                                guard let upload = status.uploads.first(where: { $0.role == resource.input.role })
                                else { throw APIClientError.invalidResponse }
                                for part in 0..<Int(upload.partCount) where !upload.completed.contains(Int32(part)) {
                                    try Task.checkCancellation()
                                    if try await store.transfers(as: ChatUploadBatch.self).first(where: {
                                        $0.id == batch.id
                                    })?.cancelRequested == true {
                                        batch.cancelRequested = true
                                        break
                                    }
                                    let bytes = try await media.read(resource.id, index: part)
                                    try await api.upload(upload.uploadID, index: part, bytes: bytes)
                                    batch.completedBytes += Int64(bytes.count)
                                    try await store.saveTransfer(batch, id: batch.id)
                                    await engine.changed()
                                }
                            }
                            if batch.cancelRequested {
                                try await cancelResources(batch)
                                break
                            }
                            status = try await api.finish(status.id, operationID: item.completeID)
                        }
                        batch.state = "processing"
                        try await store.saveTransfer(batch, id: batch.id)
                        await engine.changed()
                        while ["queued", "processing"].contains(status.state) {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            try Task.checkCancellation()
                            if try await store.transfers(as: ChatUploadBatch.self).first(where: { $0.id == batch.id })?
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
                    let latest = try await store.transfers(as: ChatUploadBatch.self).first(where: { $0.id == batch.id })
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
                        await engine.changed()
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
                    try await store.saveTransfer(batch, id: batch.id)
                    await engine.changed()
                }
            }
        } catch { await engine.changed() }
    }
    private func cancelResources(_ batch: ChatUploadBatch) async throws {
        for item in batch.items {
            if let id = item.assetID { _ = try await api.finish(id, cancel: true, operationID: item.cancelID) }
        }
        try await store.removeTransfer(batch.id)
        for resource in batch.items.flatMap(\.resources) { try? await media.remove(resource.id) }
        await engine.changed()
    }
    /// 逐段授权下载，重启后复用已认证分块；最终摘要通过后才允许明文租约。
    public func download(_ resource: ChatResource, message: String) async throws -> UUID {
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
            try await media.write(bytes, id: id, index: index)
        }
        // 即使全部命中缓存，也重新检查当前消息权限，撤回不能通过本机旧授权重新打开。
        _ = try await api.authorize(resource.id, message: message)
        try await media.verify(id)
        return id
    }
    deinit { worker?.cancel() }
}
