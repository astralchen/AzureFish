import Photos
import PhotosUI
import UniformTypeIdentifiers

/// 单项实况导入持有取消状态；取消后等待系统回调或资源写入退出，才允许调用方释放导入槽位。
@MainActor
final class LivePhotoImportRequest {
    struct Resources: Sendable {
        let photo: URL
        let video: URL
    }

    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    /// 使用提供者返回的同一个 PHLivePhoto 导出照片与视频，避免混用调整前后的资源。
    func load(provider: NSItemProvider, makeURL: (String) -> URL) async throws -> Resources {
        try checkCancellation()
        let livePhoto: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
            // iOS 27.1 的类加载也会调用异常的 readableTypeIdentifiersForItemProvider。
            // 使用明确类型的兼容接口绕过该查询；接口不返回 Progress，取消后等待回调再丢弃结果。
            provider.loadItem(forTypeIdentifier: UTType.livePhoto.identifier, options: nil) { object, error in
                if let photo = object as? PHLivePhoto { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        try checkCancellation()
        return try await export(livePhoto, makeURL: makeURL)
    }

    /// 循环等效果可能只交付 GIF/MOV；经授权读取所选资源的真实类型和原始配对。
    /// 标识仅用于定位所选资源，必须由 PhotoKit 确认 photoLive 才导出实况。
    func loadOriginalIfAvailable(assetIdentifier: String, makeURL: (String) -> URL) async throws -> Resources? {
        try checkCancellation()
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        try checkCancellation()
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject,
              asset.mediaType == .image, asset.mediaSubtypes.contains(.photoLive) else { return nil }
        // .photo 与 .pairedVideo 是同一资源的原始配对，不混用编辑后的 fullSize 资源。
        return try await export(PHAssetResource.assetResources(for: asset), makeURL: makeURL)
    }

    /// 导出同一系统实况对象的配对资源，也供真实资源的回归测试复用。
    func export(_ livePhoto: PHLivePhoto, makeURL: (String) -> URL) async throws -> Resources {
        try await export(PHAssetResource.assetResources(for: livePhoto), makeURL: makeURL)
    }

    private func export(_ resources: [PHAssetResource], makeURL: (String) -> URL) async throws -> Resources {
        try checkCancellation()
        guard let photo = resources.first(where: { $0.type == .photo }),
              let video = resources.first(where: { $0.type == .pairedVideo }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let result = Resources(
            photo: makeURL(UTType(photo.uniformTypeIdentifier)?.preferredFilenameExtension ?? "heic"),
            video: makeURL(UTType(video.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"))
        do {
            try await write(photo, to: result.photo)
            try checkCancellation()
            try await write(video, to: result.video)
            try checkCancellation()
            return result
        } catch {
            await Self.remove([result.photo, result.video])
            throw error
        }
    }

    /// writeData 没有取消接口；完成回调之前不得删除目标或归还导入槽位。
    private func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    @concurrent static func remove(_ urls: [URL]) async {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }
}
