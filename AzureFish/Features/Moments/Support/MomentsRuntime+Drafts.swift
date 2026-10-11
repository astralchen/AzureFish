import Foundation
import AzureFishAPI
import AzureFishMoments
import AzureFishStorage
import CryptoKit

extension MomentsRuntime {
    /// 持久化草稿后更新当前窗口快照；取消时不再通知页面。
    func save(_ draft: MomentsDraft) async throws {
        guard let store else { throw AccountStorageError.unavailable }
        try await store.save(draft); try Task.checkCancellation()
        drafts.removeAll { $0.id == draft.id }; drafts.insert(draft, at: 0); notify()
    }
    /// 删除尚未冻结的草稿并释放无引用媒体；发布结果不明时拒绝丢弃。
    func discard(_ draft: MomentsDraft) async throws {
        guard let store, let media else { return }
        // 不确定是否发布成功的草稿只能对账，不允许丢弃后另建身份重发。
        guard draft.publication == nil && draft.coverAsset == nil else { throw APIClientError.invalidRequest }
        try await store.removeDraft(draft.id)
        for id in draft.resources { try await store.releaseResource(id, media: media) }
        drafts.removeAll { $0.id == draft.id }; notify()
    }
    /// 将调用方提供的 JPEG 数据分块加密并校验完整性，保存草稿引用后结束导入预留。
    func importImage(_ data: Data, draft: MomentsDraft, cover: Bool = false) async throws -> MomentsDraft {
        guard let store, let media, draft.video == nil, data.count <= 25 * 1024 * 1024, draft.images.count < (cover ? 1 : 9) else { throw APIClientError.invalidRequest }
        let id = UUID(), hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = MediaResourceDescriptor(role: "moments-draft", filename: "image.jpg", mime: "image/jpeg", bytes: Int64(data.count), sha256: hash)
        try await store.reserve(id)
        try await media.prepare(id: id, input: descriptor)
        for (index, start) in stride(from: 0, to: data.count, by: EncryptedMediaStore.chunkBytes).enumerated() {
            try await media.write(data.subdata(in: start..<min(start + EncryptedMediaStore.chunkBytes, data.count)), id: id, index: index)
        }
        try await media.verify(id); try Task.checkCancellation()
        var value = draft; value.images.append(.init(id: id, descriptor: descriptor)); value.updatedAt = Date()
        try await save(value); try await store.finishImport(id)
        return value
    }
    /// 上传媒体并发布草稿；已冻结草稿先按动态 ID 对账，再原样重试请求。
    ///
    /// 仅明确的字段校验失败会解冻正文；网络失败等未知结果保留冻结请求供重试。
    func publish(_ draft: MomentsDraft, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws {
        guard let store, let media, let api, let manager = session?.sessionManager else { throw AccountStorageError.unavailable }
        refreshVersion = UUID(); var value = draft
        if value.publication != nil {
            do {
                let accepted = try await api.result(value.id.uuidString.lowercased())
                try Task.checkCancellation(); try await finish(accepted, draft: value); return
            } catch { guard isMomentUnavailable(error) else { throw error } }
        }
        if value.publication == nil {
            guard value.text.count <= 2000, value.text.utf8.count <= 64 * 1024, AccountValidation.text(value.text),
                  !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !value.images.isEmpty || value.video?.output != nil,
                  value.images.count <= 9, value.video == nil || (value.images.isEmpty && value.video?.output != nil) else { throw APIClientError.invalidRequest }
            let transfer = MomentsTransfer(store: store, media: media, api: MediaAPI(session: manager))
            var assets: [String] = []
            for index in value.images.indices {
                let image = value.images[index], snapshot = value
                let asset = try await transfer.upload(image) { updated in
                    var saved = snapshot; saved.images[index] = updated
                    try await store.save(saved)
                }
                value.images[index].assetID = asset.id; assets.append(asset.id); try await save(value)
            }
            var videoAsset: String?
            if let video = value.video, let output = video.output {
                let capabilities = try await transfer.api.capabilities()
                guard capabilities.available, capabilities.momentsVideoMaxDuration > 0, video.duration > 0,
                      video.duration <= min(60_000, capabilities.momentsVideoMaxDuration), output.descriptor.bytes <= capabilities.videoBytes else { throw APIClientError.invalidRequest }
                let snapshot = value
                let asset = try await transfer.upload(output, kind: "video", progress: progress) { updated in
                    var saved = snapshot; saved.video?.output = updated; try await store.save(saved)
                }
                value.video?.output?.assetID = asset.id; videoAsset = asset.id; try await save(value)
            }
            // 发送前固定并落盘请求字节，崩溃或响应丢失后仍使用同一发布身份和内容。
            value.publication = try MomentsAPI.publication(id: value.id, operation: value.operation, text: value.text, assets: assets, video: videoAsset)
            try await save(value)
        }
        do {
            let result = try await api.publish(bytes: value.publication!)
            try Task.checkCancellation(); try await finish(result, draft: value)
        } catch {
            // 明确的字段校验拒绝未提交事务，允许用户修改原草稿；未知结果仍保持冻结。
            if case APIClientError.service(let failure) = error, failure.code == .validationFailed {
                value.publication = nil; value.operation = UUID(); try await save(value)
            }
            throw error
        }
    }
    /// 保存服务端快照后删除草稿、释放本地媒体，并通知其他窗口重新读取。
    private func finish(_ post: MomentsPost, draft: MomentsDraft) async throws {
        guard let store, let media else { throw CancellationError() }
        try await store.merge([post]); try await store.removeDraft(draft.id)
        for id in draft.resources { try await store.releaseResource(id, media: media) }
        try await restore(); broadcast()
    }
}
