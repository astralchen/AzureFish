import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import Foundation

extension MomentsRuntime {
    /// 导入系统临时视频后立即登记加密草稿；未导出的视频可在重启后继续编辑。
    func importVideo(_ url: URL, draft: MomentsDraft) async throws -> MomentsDraft {
        guard let store, let media, draft.images.isEmpty, draft.video == nil, !draft.isCover,
              draft.publication == nil else { throw APIClientError.invalidRequest }
        let id = UUID()
        try await store.reserve(id)
        let local = try await media.importFile(url, filename: url.lastPathComponent, mime: url.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4", role: "moments-video-source", id: id)
        try Task.checkCancellation()
        var result = draft
        result.video = MomentsVideoDraft(source: .init(id: id, descriptor: local.input))
        result.updatedAt = Date()
        try await save(result); try await store.finishImport(id)
        return result
    }
    /// 用新身份保存导出结果和封面；已开始发布对账的草稿不能替换媒体。
    func saveVideo(_ url: URL, poster: URL, duration: Int64, width: Int32, height: Int32, draft: MomentsDraft) async throws -> MomentsDraft {
        guard let store, let media, draft.video != nil, draft.publication == nil,
              duration > 0, duration <= 60_000 else { throw APIClientError.invalidRequest }
        let id = UUID(), posterID = UUID()
        try await store.reserve(id); try await store.reserve(posterID)
        let video = try await media.importFile(url, filename: "video.mp4", mime: "video/mp4", role: "moments-video-draft", id: id)
        let cover = try await media.importFile(poster, filename: "cover.jpg", mime: "image/jpeg", role: "moments-video-poster", id: posterID)
        try Task.checkCancellation()
        var result = draft
        result.video?.output = .init(id: id, descriptor: video.input)
        result.video?.poster = .init(id: posterID, descriptor: cover.input)
        result.video?.duration = duration; result.video?.width = width; result.video?.height = height
        result.video?.trimDuration = Double(duration) / 1000
        result.updatedAt = Date()
        // 新草稿引用落盘后才释放导入预留，避免中断恢复误删已保存的导出结果。
        try await save(result)
        try await store.finishImport(id); try await store.finishImport(posterID)
        try await store.recoverCleanup(media: media)
        return result
    }
    /// 移除未冻结草稿的视频引用，再清理不再使用的源文件、导出文件和封面。
    func removeVideo(_ draft: MomentsDraft) async throws -> MomentsDraft {
        guard let store, let media, draft.publication == nil else { throw APIClientError.invalidRequest }
        var result = draft; result.video = nil; result.updatedAt = Date()
        try await save(result); try await store.recoverCleanup(media: media)
        return result
    }
    /// 在线重新授权，复用完整或部分加密缓存；返回的租约由播放器关闭时释放。
    func videoLease(_ asset: ChatAsset, target: String, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        guard referencesImage(asset, target: target, cover: false), asset.kind == "video",
              let resource = asset.resources.first(where: { $0.role == "original" }),
              let store, let media else { throw MediaStorageError.unavailable }
        do {
            let id: UUID
            if offline {
                guard let resourceID = UUID(uuidString: resource.id), try await store.containsResource(resourceID, target: target, cover: false) else { throw MediaStorageError.unavailable }
                try await media.verify(resourceID); id = resourceID
            } else {
                guard let manager = session?.sessionManager else { throw MediaStorageError.unavailable }
                id = try await MomentsTransfer(store: store, media: media, api: MediaAPI(session: manager))
                    .download(resource, target: target, offline: false, progress: progress)
            }
            try Task.checkCancellation()
            guard referencesImage(asset, target: target, cover: false) else { throw MediaStorageError.unavailable }
            return try await media.lease(id)
        } catch {
            if isMomentUnavailable(error) {
                try await store.removePosts([target]); try await restore()
            }
            throw error
        }
    }
}
