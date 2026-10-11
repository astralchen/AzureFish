import Foundation
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage

extension MomentsRuntime {
    /// 上传封面并按草稿中的相册版本提交；成功后移除草稿和不再引用的媒体。
    func setCover(_ draft: MomentsDraft) async throws {
        guard let store, let media, let manager = session?.sessionManager, let image = draft.images.first else { throw MediaStorageError.unavailable }
        var value = draft
        if value.coverAsset == nil {
            let asset = try await MomentsTransfer(store: store, media: media, api: MediaAPI(session: manager)).upload(image, cover: true) { updated in
                var value = draft; value.images[0] = updated; try await store.save(value)
            }
            value.images[0].assetID = asset.id; value.coverAsset = asset.id
            try await save(value)
        }
        do {
            try await mutate(.init(kind: .cover, asset: value.coverAsset!, revision: value.coverRevision, id: value.operation))
        } catch {
            if case APIClientError.service(let failure) = error, failure.code == .momentVersionConflict, let api {
                // 版本冲突明确未覆盖相册，读取新版本并换操作身份，让下一次确认可重新提交。
                let current = try await api.album(userID)
                value.coverRevision = current.revision; value.coverAsset = nil; value.operation = UUID()
                try await save(value); albums[userID] = current
            }
            throw error
        }
        try await store.removeDraft(value.id)
        for image in value.images { try await store.releaseResource(image.id, media: media) }
        try await restore()
    }
}
