import AVFoundation
import AzureFishStorage
import AzureFishAPI
import AzureFishMoments
import ImageIO
import PhotosUI
import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

extension MomentsComposerViewController {
    func pick() {
        var config = PHPickerConfiguration(photoLibrary: .shared()); config.filter = .images; config.selectionLimit = (isCover ? 1 : 9) - draft.images.count
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
    }
    /// 接收选择结果并按选择顺序导入；封面先交给裁剪页确认，再保存到草稿。
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        if let provider = results.first?.itemProvider, provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            receiveVideo(provider); return
        }
        busy = true; errorKey = nil; viewModel.cancelPendingSave(); updateControls()
        runtime.launch { [weak self] in
            guard let self else { return }; defer { busy = false; updateControls() }
            do {
                for result in results {
                    let data = try await Self.jpeg(result.itemProvider)
                    try Task.checkCancellation()
                    if isCover, let image = UIImage(data: data) {
                        let crop = MomentsCoverCropController(image: image) { [weak self] bytes in
                            guard let self else { return }
                            runtime.launch {
                                try self.viewModel.replaceDraft(await self.runtime.importImage(bytes, draft: self.draft, cover: true))
                                self.updateControls()
                            }
                        }
                        navigationController?.pushViewController(crop, animated: true)
                    } else { try viewModel.replaceDraft(await runtime.importImage(data, draft: draft)) }
                }
            } catch { errorKey = momentsErrorKey(error); throw error }
        }
    }
    /// 在系统文件回调有效期内下采样并重新编码，避免大图全尺寸解码和位置元数据持久化。
    nonisolated static func jpeg(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                    continuation.resume(throwing: error ?? APIClientError.invalidRequest); return
                }
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continuation.resume(throwing: APIClientError.invalidRequest); return }
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { continuation.resume(throwing: APIClientError.invalidRequest); return }
                continuation.resume(returning: data as Data)
            }
        }
    }
}
