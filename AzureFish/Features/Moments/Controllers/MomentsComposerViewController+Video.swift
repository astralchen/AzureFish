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

extension MomentsComposerViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIVideoEditorControllerDelegate {
    func chooseMedia() {
        guard !busy else { return }
        if isCover || !draft.images.isEmpty { pick(); return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: Localization.text("moments.addPhotos"), style: .default) { [weak self] _ in self?.pick() })
        alert.addAction(UIAlertAction(title: Localization.text("moments.videoChoose"), style: .default) { [weak self] _ in
            var config = PHPickerConfiguration(photoLibrary: .shared()); config.filter = .videos; config.selectionLimit = 1
            let picker = PHPickerViewController(configuration: config); picker.delegate = self; self?.present(picker, animated: true)
        })
        alert.addAction(UIAlertAction(title: Localization.text("moments.videoRecord"), style: .default) { [weak self] _ in self?.recordVideo() })
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = add; alert.popoverPresentationController?.sourceRect = add.bounds
        present(alert, animated: true)
    }
    func recordVideo() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { errorKey = "moments.cameraUnavailable"; updateControls(); return }
        busy = true; viewModel.cancelPendingSave(); updateControls()
        runtime.launch { [weak self] in
            guard let self else { return }; defer { busy = false; updateControls() }
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            try Task.checkCancellation()
            guard camera && microphone else { errorKey = "moments.cameraPermission"; return }
            let picker = UIImagePickerController(); picker.sourceType = .camera; picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video; picker.videoMaximumDuration = 60; picker.videoQuality = .typeHigh
            picker.delegate = self; present(picker, animated: true)
        }
    }
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard let source = info[.mediaURL] as? URL else { picker.dismiss(animated: true); return }
        busy = true; viewModel.cancelPendingSave(); updateControls()
        runtime.launch { [weak self] in
            guard let self else { return }; defer { busy = false; updateControls(); try? FileManager.default.removeItem(at: source) }
            do {
                try viewModel.replaceDraft(await runtime.importVideo(source, draft: draft))
                picker.dismiss(animated: true) { [weak self] in self?.editVideo() }
            } catch { picker.dismiss(animated: true); errorKey = momentsErrorKey(error); throw error }
        }
    }
    /// 将选择器临时文件复制到账号临时目录，加密导入成功后释放副本并打开裁剪器。
    func receiveVideo(_ provider: NSItemProvider) {
        busy = true; viewModel.cancelPendingSave(); errorKey = nil; updateControls()
        runtime.launch { [weak self] in
            guard let self, let media = runtime.media else { return }; var imported = false
            defer { busy = false; updateControls(); if imported { editVideo() } }
            let url = try await media.temporaryFile(filename: "source.mov")
            do {
                try await Self.copyVideo(provider, to: url)
                try viewModel.replaceDraft(await runtime.importVideo(url, draft: draft))
                try await media.release(url)
                imported = true
            } catch { try? await media.release(url); errorKey = momentsErrorKey(error); throw error }
        }
    }
    /// 在系统文件回调有效期内完成复制；output 的保护、租约和清理由调用方负责。
    nonisolated static func copyVideo(_ provider: NSItemProvider, to output: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                do {
                    guard let url else { throw error ?? APIClientError.invalidRequest }
                    try FileManager.default.copyItem(at: url, to: output); continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    /// 为加密源视频申请明文租约并交给系统裁剪器；未发布草稿才允许编辑。
    func editVideo() {
        guard !busy, draft.publication == nil, let source = draft.video?.source else { return }
        busy = true; viewModel.cancelPendingSave(); updateControls()
        runtime.launch { [weak self] in
            guard let self, let media = runtime.media else { return }; defer { busy = false; updateControls() }
            do {
                let url = try await media.lease(source.id)
                guard UIVideoEditorController.canEditVideo(atPath: url.path) else {
                    try await media.release(url); errorKey = "moments.videoEditorUnavailable"; return
                }
                errorKey = nil
                editingLease = (media, url)
                let editor = UIVideoEditorController(); editor.videoPath = url.path; editor.videoMaximumDuration = 60
                editor.videoQuality = .typeHigh; editor.delegate = self
                editor.view.accessibilityIdentifier = "moments.video.trimmer"
                present(editor, animated: true)
            } catch { errorKey = momentsErrorKey(error); throw error }
        }
    }
    /// 清空页面持有的编辑租约并异步请求释放；重复调用不会重复调度同一租约。
    func releaseEditorLease() {
        if let (media, url) = editingLease { Task { try? await media.release(url) } }; editingLease = nil
    }
    func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
        editor.dismiss(animated: true); releaseEditorLease()
    }
    func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: any Error) {
        editor.dismiss(animated: true); releaseEditorLease(); errorKey = momentsErrorKey(error); updateControls()
    }
    /// 接收系统选段，导出兼容视频和封面并加密保存；完成或失败后释放编辑租约。
    func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath editedVideoPath: String) {
        busy = true; viewModel.setProgress(0); updateControls()
        runtime.launch { [weak self] in
            guard let self, let media = runtime.media else { return }
            defer { busy = false; updateControls(); releaseEditorLease() }
            let selected = try await media.temporaryFile(filename: "selected.mov")
            let edited = URL(fileURLWithPath: editedVideoPath)
            do { try FileManager.default.copyItem(at: edited, to: selected) }
            catch { try? await media.release(selected); editor.dismiss(animated: true); throw error }
            // 裁剪器返回的是新生成的临时文件；复制到账号租约后结束系统编辑器的访问。
            if edited != editingLease?.1 { try? FileManager.default.removeItem(at: edited) }
            editor.dismiss(animated: true)
            let output = try await media.temporaryFile(filename: "video.mp4")
            let poster = try await media.temporaryFile(filename: "cover.jpg")
            do {
                let metadata = try await MomentsVideoProcessor.export(selected, to: output, poster: poster) { [weak self] value in self?.viewModel.setProgress(value) }
                try viewModel.replaceDraft(await runtime.saveVideo(output, poster: poster, duration: metadata.duration, width: metadata.width, height: metadata.height, draft: draft))
                try await media.release(selected); try await media.release(output); try await media.release(poster)
            } catch { try? await media.release(selected); try? await media.release(output); try? await media.release(poster); errorKey = momentsErrorKey(error); throw error }
        }
    }
}
