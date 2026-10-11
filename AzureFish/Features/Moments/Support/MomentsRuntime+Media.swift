import Foundation
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import UIKit

extension MomentsRuntime {
    /// 读取动态图片或封面数据；在线重新授权，离线仅读取仍有引用且校验完整的缓存。
    ///
    /// original 为 false 时选择图片缩略图或视频封面；图片缺少目标角色时可回退到首个资源。
    func image(_ asset: ChatAsset, target: String, cover: Bool = false, original: Bool = false) async throws -> Data {
        #if DEBUG
        if !previewUser.isEmpty, let index = Int(asset.id) {
            return MomentsPreviewData.image(index, size: CGSize(width: max(1, Int(asset.width)), height: max(1, Int(asset.height))))
        }
        #endif
        guard let store, let media,
              let resource = asset.resources.first(where: { $0.role == (original ? "original" : (asset.kind == "video" ? "cover" : "thumbnail")) }) ?? (asset.kind == "video" ? nil : asset.resources.first) else { throw MediaStorageError.unavailable }
        let identity = epoch
        do {
            if offline {
                guard let id = UUID(uuidString: resource.id), resource.bytes <= 25 * 1024 * 1024,
                      try await store.containsResource(id, target: target, cover: cover) else { throw MediaStorageError.unavailable }
                try await media.verify(id)
                let descriptor = MediaResourceDescriptor(role: resource.role, filename: resource.filename, mime: resource.mime, bytes: resource.bytes, sha256: resource.sha256)
                let bytes = try await localImage(.init(id: id, descriptor: descriptor))
                try Task.checkCancellation()
                guard referencesImage(asset, target: target, cover: cover) else { throw MediaStorageError.unavailable }
                return bytes
            }
            guard let manager = session?.sessionManager else { throw MediaStorageError.unavailable }
            return try await MomentsTransfer(store: store, media: media, api: MediaAPI(session: manager)).image(resource, target: target, cover: cover, offline: offline)
        } catch {
            if isMomentUnavailable(error), !cover, identity == epoch {
                // 授权明确失效时立即撤回缩略图和原图，不能把它当作普通下载失败保留预览。
                try? await store.removePosts([target])
                if identity == epoch { posts.removeAll { $0.id == target }; notify() }
            }
            throw error
        }
    }
    /// 按描述中的字节数读取本地加密草稿；调用方负责确保资源已经完成导入与校验。
    func localImage(_ image: MomentsImageDraft) async throws -> Data {
        guard let media else { throw MediaStorageError.unavailable }
        var bytes = Data()
        for index in 0..<Int((image.descriptor.bytes + Int64(EncryptedMediaStore.chunkBytes) - 1) / Int64(EncryptedMediaStore.chunkBytes)) { bytes.append(try await media.read(image.id, index: index)) }
        return bytes
    }
}
