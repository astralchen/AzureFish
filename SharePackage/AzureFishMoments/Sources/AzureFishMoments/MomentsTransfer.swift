import AzureFishAPI
import AzureFishStorage
import Foundation

/// 媒体处理的稳定失败码，不携带资源内容或凭据。
public enum MomentsMediaError: Error, Sendable { case processingFailed(String) }

/// 执行发布和读取中的媒体传输；调用方管理任务取消，上传恢复以服务端分块状态为准。
public struct MomentsTransfer: Sendable {
    public let store: MomentsStore
    public let media: EncryptedMediaStore
    public let api: MediaAPI
    public init(store: MomentsStore, media: EncryptedMediaStore, api: MediaAPI) { self.store = store; self.media = media; self.api = api }
    /// 恢复分块上传并轮询处理结果，成功时返回可发布的资产。
    ///
    /// - Parameters:
    ///   - image: 包含稳定操作 ID 和可选服务端资产 ID 的本地资源记录。
    ///   - cover: 是否创建相册封面资产；默认为动态媒体。
    ///   - kind: 服务端媒体类型，默认为 image，视频传 video。
    ///   - progress: 上传进度回调；值为分块位置比例，1 不表示服务端处理完成。
    ///   - save: 创建资产后持久化其 ID 的异步回调；失败时停止本次上传。
    /// - Throws: 取消、存储或网络错误，以及处理失败或轮询期限耗尽。
    public func upload(_ image: MomentsImageDraft, cover: Bool = false, kind: String = "image",
                       progress: @Sendable (Double) async -> Void = { _ in },
                       save: @Sendable (MomentsImageDraft) async throws -> Void) async throws -> ChatAsset {
        var image = image
        let descriptor = image.descriptor
        var status: ChatAssetStatus
        if let asset = image.assetID { status = try await api.status(asset) }
        else {
            status = try await api.create(conversation: "", kind: kind, resources: [.init(filename: descriptor.filename,
                mime: descriptor.mime, bytes: descriptor.bytes, sha256: descriptor.sha256)], operationID: image.createOperation,
                purpose: cover ? "moments_cover" : "moments_post")
            // 先保存服务端身份再传分块，重启后可查询已完成分块而不重复创建资产。
            image.assetID = status.id; try await save(image)
        }
        try Task.checkCancellation()
        if status.state == "uploading" {
            guard let upload = status.uploads.first(where: { $0.role == "original" }) else { throw MediaStorageError.unavailable }
            for index in 0..<Int(upload.partCount) where !upload.completed.contains(Int32(index)) {
                try Task.checkCancellation()
                try await api.upload(upload.uploadID, index: index, bytes: media.read(image.id, index: index))
                await progress(Double(index + 1) / Double(upload.partCount))
            }
            await progress(1)
            status = try await api.finish(status.id, operationID: image.completeOperation)
        }
        for _ in 0..<130 {
            try Task.checkCancellation()
            if status.state == "ready" { return status.asset }
            if status.state == "failed" { throw MomentsMediaError.processingFailed(status.failure) }
            guard ["queued", "processing"].contains(status.state) else { throw MediaStorageError.unavailable }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            status = try await api.status(status.id)
        }
        throw MediaStorageError.unavailable
    }
    /// 分块加密缓存只在完整摘要校验后返回；在线每次重新申请当前权限授权。
    public func image(_ resource: ChatResource, target: String, cover: Bool, offline: Bool) async throws -> Data {
        guard resource.bytes <= 25 * 1024 * 1024 else { throw MediaStorageError.invalidResource }
        let id = try await download(resource, target: target, cover: cover, offline: offline)
        var bytes = Data()
        for index in 0..<Int((resource.bytes + Int64(EncryptedMediaStore.chunkBytes) - 1) / Int64(EncryptedMediaStore.chunkBytes)) {
            bytes.append(try await media.read(id, index: index))
        }
        try Task.checkCancellation()
        return bytes
    }
    /// 完整校验后返回加密资源身份，调用方按播放生命周期申请和释放租约。
    public func download(_ resource: ChatResource, target: String, cover: Bool = false, offline: Bool,
                         progress: @Sendable (Double) async -> Void = { _ in }) async throws -> UUID {
        guard let id = UUID(uuidString: resource.id), resource.bytes > 0, resource.bytes <= 512 * 1024 * 1024 else { throw MediaStorageError.invalidResource }
        guard try await store.containsResource(id, target: target, cover: cover) else { throw MediaStorageError.unavailable }
        // 即使所有分块已缓存，在线读取也必须重新授权，不能以缓存命中绕过权限。
        if !offline {
            let grant = try await api.authorizeMoments(resource.id, target: target, cover: cover)
            try await media.prepare(id: id, input: .init(role: "moments:" + resource.role, filename: resource.filename,
                mime: resource.mime, bytes: resource.bytes, sha256: resource.sha256))
            let completed = try await media.completed(id)
            for index in 0..<Int((resource.bytes + Int64(EncryptedMediaStore.chunkBytes) - 1) / Int64(EncryptedMediaStore.chunkBytes)) where !completed.contains(index) {
                let offset = Int64(index * EncryptedMediaStore.chunkBytes)
                let bytes = try await api.download(grant, offset: offset, count: Int(min(Int64(EncryptedMediaStore.chunkBytes), resource.bytes - offset)))
                try await media.write(bytes, id: id, index: index)
                await progress(min(1, Double(offset + Int64(bytes.count)) / Double(resource.bytes)))
            }
        }
        try await media.verify(id)
        // 网络等待期间动态可能被删除或失权，返回前再次核对本地引用。
        guard try await store.containsResource(id, target: target, cover: cover) else {
            try await store.releaseResource(id, media: media)
            throw MediaStorageError.unavailable
        }
        try Task.checkCancellation()
        await progress(1)
        return id
    }
}
