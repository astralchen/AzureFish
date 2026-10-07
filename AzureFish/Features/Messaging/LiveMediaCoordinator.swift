import AzureFishStorage
import AVFoundation
import AVKit
import AzureFishAPI
import AzureFishChat
@preconcurrency import Photos
import PhotosUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// 连接系统媒体选择、录音与受限明文租约，原件上传保持字节不变。
@MainActor
final class LiveMediaCoordinator: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
    QLPreviewControllerDataSource, QLPreviewControllerDelegate
{
    private weak var controller: LiveConversationViewController?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingURL: URL?
    private var recordingMedia: ChatMediaStore?
    private var recordingStarted: Date?
    private var timer: Task<Void, Never>?
    private var lease: URL?
    private var leaseMedia: ChatMediaStore?
    private var taskID: UUID?
    private var task: Task<Void, Never>?
    init(controller: LiveConversationViewController) { self.controller = controller }
    func choose() {
        guard let controller else { return }
        let sheet = UIAlertController(
            title: Localization.text("chat.live.attach"),
            message: controller.editor.text.isEmpty ? nil : Localization.text("chat.live.splitHelp"),
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.photos"), style: .default) { [weak self] _ in
                self?.photos()
            })
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.file"), style: .default) { [weak self] _ in self?.files()
            })
        if !controller.attachments.isEmpty {
            sheet.addAction(
                UIAlertAction(title: Localization.text("chat.live.reviewAttachments"), style: .default) {
                    [weak self] _ in self?.review()
                })
        }
        sheet.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.attachmentButton
        sheet.popoverPresentationController?.sourceRect = controller.attachmentButton.bounds
        controller.present(sheet, animated: true)
    }
    private func photos() {
        guard let controller else { return }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = max(1, 20 - controller.attachments.count)
        config.selection = .ordered
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        controller.present(picker, animated: true)
    }
    private func files() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.delegate = self
        controller?.present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let controller, let media = controller.runtime.media, let engine = controller.runtime.engine else { return }
        let id = beginOperation()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id) }
            let batch: UUID
            do { batch = try await engine.store.beginMediaImport() } catch { controller.showFailure(); return }
            var temporary: [URL] = []
            do {
                for result in results {
                    try Task.checkCancellation()
                    let provider = result.itemProvider
                    if provider.canLoadObject(ofClass: PHLivePhoto.self) {
                        let live: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
                            provider.loadObject(ofClass: PHLivePhoto.self) { object, error in
                                if let live = object as? PHLivePhoto {
                                    continuation.resume(returning: live)
                                } else {
                                    continuation.resume(throwing: error ?? ChatMediaStoreError.unavailable)
                                }
                            }
                        }
                        let resources = PHAssetResource.assetResources(for: live)
                        var imported: [ChatLocalMedia] = []
                        for resource in resources where resource.type == .photo || resource.type == .pairedVideo {
                            let url = try await media.temporaryFile(filename: resource.originalFilename)
                            temporary.append(url)
                            let options = PHAssetResourceRequestOptions()
                            options.isNetworkAccessAllowed = true
                            try await withCheckedThrowingContinuation {
                                (continuation: CheckedContinuation<Void, Error>) in
                                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
                                { error in
                                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                                }
                            }
                            do {
                                let value = try await engine.store.importMedia(
                                    url, filename: resource.originalFilename,
                                    mime: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType
                                        ?? "application/octet-stream",
                                    role: resource.type == .pairedVideo ? "paired_video" : "original", using: media, batch: batch)
                                imported.append(value)
                                try await media.release(url)
                            } catch {
                                try? await media.release(url)
                                throw error
                            }
                        }
                        guard imported.count == 2 else { throw ChatMediaStoreError.invalidResource }
                        try await controller.acceptImported(.init(kind: "live_photo", resources: imported), batch: batch, engine: engine)
                    } else {
                        let family = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? UTType.movie : UTType.image
                        let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first { $0.conforms(to: family) && $0.preferredFilenameExtension != nil } ?? family
                        let destination = try await media.temporaryFile(
                            filename: (provider.suggestedName ?? "media") + "." + (type.preferredFilenameExtension ?? (type.conforms(to: .movie) ? "mov" : "jpg")))
                        temporary.append(destination)
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                                do {
                                    guard let url else { throw error ?? ChatMediaStoreError.unavailable }
                                    try FileManager.default.copyItem(at: url, to: destination)
                                    continuation.resume()
                                } catch { continuation.resume(throwing: error) }
                            }
                        }
                        let value = try await engine.store.importMedia(
                            destination, filename: destination.lastPathComponent,
                            mime: UTType(filenameExtension: destination.pathExtension)?.preferredMIMEType
                                ?? (type.conforms(to: .movie) ? "video/quicktime" : "image/jpeg"), using: media, batch: batch)
                        try await media.release(destination)
                        try await controller.acceptImported(.init(kind: type.conforms(to: .movie) ? "video" : "image", resources: [value]), batch: batch, engine: engine)
                    }
                }
                for url in temporary { try? await media.release(url) }
                if !Task.isCancelled, controller.runtime.engine === engine { review() }
            } catch {
                for url in temporary { try? await media.release(url) }
                try? await engine.store.cancelMediaImport(batch)
                try? await engine.store.cleanupMedia(using: media)
                if !(error is CancellationError) { controller.showFailure() }
            }
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let owner = self.controller, let media = owner.runtime.media, let engine = owner.runtime.engine, let url = urls.first else { return }
        let id = beginOperation()
        task = Task { [weak self] in
            defer { self?.finishOperation(id) }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let batch: UUID
            do { batch = try await engine.store.beginMediaImport() } catch { owner.showFailure(); return }
            do {
                let value = try await engine.store.importMedia(
                    url, filename: url.lastPathComponent, mime: "application/octet-stream", using: media, batch: batch)
                try await owner.acceptImported(.init(kind: "file", resources: [value]), batch: batch, engine: engine)
                self?.review()
            } catch {
                try? await engine.store.cancelMediaImport(batch)
                try? await engine.store.cleanupMedia(using: media)
                if !(error is CancellationError) { owner.showFailure() }
            }
        }
    }
    func review() {
        guard let controller else { return }
        let sheet = UIAlertController(
            title: Localization.text("chat.live.reviewAttachments"), message: Localization.text("chat.live.splitHelp"),
            preferredStyle: .actionSheet)
        for (index, item) in controller.attachments.enumerated() {
            let name = item.resources.first?.input.filename ?? item.kind
            sheet.addAction(
                UIAlertAction(title: "\(index+1). \(name)", style: .default) { [weak self] _ in
                    self?.editAttachment(index)
                })
        }
        sheet.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.attachmentButton
        sheet.popoverPresentationController?.sourceRect = controller.attachmentButton.bounds
        controller.present(sheet, animated: true)
    }
    private func editAttachment(_ index: Int) {
        guard let controller, controller.attachments.indices.contains(index) else { return }
        let sheet = UIAlertController(
            title: controller.attachments[index].resources.first?.input.filename, message: nil,
            preferredStyle: .actionSheet)
        if index > 0 {
            sheet.addAction(
                UIAlertAction(title: Localization.text("chat.live.moveEarlier"), style: .default) { _ in
                    controller.attachments.swapAt(index, index - 1)
                    self.review()
                })
        }
        if index + 1 < controller.attachments.count {
            sheet.addAction(
                UIAlertAction(title: Localization.text("chat.live.moveLater"), style: .default) { _ in
                    controller.attachments.swapAt(index, index + 1)
                    self.review()
                })
        }
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.remove"), style: .destructive) { _ in
                controller.attachments.remove(at: index)
            })
        sheet.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.attachmentButton
        sheet.popoverPresentationController?.sourceRect = controller.attachmentButton.bounds
        controller.present(sheet, animated: true)
    }
    func record() {
        guard recorder == nil else {
            stopRecording()
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                if allowed { await self.beginRecording() } else { self.showMicrophonePermission() }
            }
        }
    }
    private func showMicrophonePermission() {
        guard let controller else { return }
        let alert = UIAlertController(title: Localization.text("chat.permission.microphone"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("chat.permission.settings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        })
        controller.present(alert, animated: true)
    }
    private func beginRecording() async {
        guard let media = controller?.runtime.media else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = try await media.temporaryFile(filename: "voice.m4a")
            guard controller?.runtime.media === media else { try? await media.release(url); return }
            recordingURL = url; recordingMedia = media
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ])
            self.recorder = recorder
            recordingStarted = Date()
            guard recorder.record(forDuration: 120) else { throw ChatMediaStoreError.unavailable }
            controller?.voiceButton.setImage(UIImage(systemName: "stop.circle.fill"), for: .normal)
            timer = Task {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                if !Task.isCancelled { stopRecording() }
            }
        } catch {
            if let recordingURL { try? await media.release(recordingURL) }
            recordingURL = nil; recordingMedia = nil
            if controller?.runtime.media === media { controller?.showFailure() }
        }
    }
    private func stopRecording() {
        guard let controller, let recorder, let url = recordingURL else { return }
        let duration = max(recorder.currentTime, min(120, recordingStarted.map { Date().timeIntervalSince($0) } ?? 0))
        recorder.stop()
        self.recorder = nil
        timer?.cancel()
        timer = nil
        controller.voiceButton.setImage(UIImage(systemName: "mic"), for: .normal)
        let sheet = UIAlertController(
            title: Localization.text("chat.live.voicePreview"), message: nil, preferredStyle: .alert)
        if duration >= 1 { sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.listen"), style: .default) { [weak self] _ in
                do {
                    self?.player = try AVAudioPlayer(contentsOf: url)
                    self?.player?.play()
                    self?.voiceReview(url)
                } catch { controller.showFailure() }
            }) }
        sheet.addAction(UIAlertAction(title: Localization.text("chat.live.recordAgain"), style: .default) { [weak self] _ in
            Task { try? await controller.runtime.media?.release(url); await self?.beginRecording() }
        })
        if duration >= 1 {
            sheet.addAction(
                UIAlertAction(title: Localization.text("chat.live.keepRecording"), style: .default) { [weak self] _ in
                    self?.importRecording(url)
                })
        }
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel) { _ in
                Task { try? await controller.runtime.media?.release(url) }
            })
        controller.present(sheet, animated: true)
    }
    private func voiceReview(_ url: URL) {
        guard let controller else { return }
        let alert = UIAlertController(
            title: Localization.text("chat.live.voicePreview"), message: nil, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: Localization.text("chat.live.keepRecording"), style: .default) { _ in
                self.player?.stop()
                self.importRecording(url)
            })
        alert.addAction(
            UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel) { _ in
                self.player?.stop()
                Task { try? await controller.runtime.media?.release(url) }
            })
        controller.present(alert, animated: true)
    }
    private func importRecording(_ url: URL) {
        guard let controller, let media = controller.runtime.media, let engine = controller.runtime.engine else { return }
        let id = beginOperation()
        task = Task {
            defer { finishOperation(id) }
            let batch: UUID
            do { batch = try await engine.store.beginMediaImport() } catch {
                try? await media.release(url); controller.showFailure(); return
            }
            do {
                let value = try await engine.store.importMedia(url, filename: "voice.m4a", mime: "audio/mp4", using: media, batch: batch)
                try await media.release(url)
                try await controller.acceptImported(.init(kind: "audio", resources: [value]), batch: batch, engine: engine)
                review()
            } catch {
                try? await engine.store.cancelMediaImport(batch)
                try? await engine.store.cleanupMedia(using: media)
                try? await media.release(url)
                if !(error is CancellationError) { controller.showFailure() }
            }
        }
    }
    func open(_ message: ChatMessage) {
        guard let controller, !message.assets.isEmpty else { return }
        let resources = message.assets.flatMap(\.resources).filter { $0.role == "original" }
        if resources.count == 1 {
            download(resources[0], message: message.id)
        } else {
            let sheet = UIAlertController(
                title: Localization.text("chat.live.open"), message: nil, preferredStyle: .actionSheet)
            for resource in resources {
                sheet.addAction(
                    UIAlertAction(title: resource.filename, style: .default) { [weak self] _ in
                        self?.download(resource, message: message.id)
                    })
            }
            sheet.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = controller.view
            controller.present(sheet, animated: true)
        }
    }
    /// 导出期间保留受保护租约，系统分享结束后释放所有临时明文。
    func export(_ message: ChatMessage) {
        guard let controller, let queue = controller.runtime.transfers, let media = controller.runtime.media, task == nil else { return }
        let id = beginOperation()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id) }
            var urls: [URL] = []
            do {
                for resource in message.assets.flatMap(\.resources).filter({ $0.role == "original" }) {
                    let id = try await queue.download(resource, message: message.id)
                    try Task.checkCancellation()
                    urls.append(try await media.lease(id))
                }
                try Task.checkCancellation()
                guard taskID == id, controller.runtime.transfers === queue else { throw CancellationError() }
                guard !urls.isEmpty else { throw ChatMediaStoreError.unavailable }
                let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                let leases = urls
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    Task { for url in leases { try? await media.release(url) } }
                }
                sheet.popoverPresentationController?.sourceView = controller.list
                sheet.popoverPresentationController?.sourceRect = controller.list.bounds.intersection(controller.view.bounds)
                controller.present(sheet, animated: true)
            } catch {
                for url in urls { try? await media.release(url) }
                if !(error is CancellationError) { controller.showFailure() }
            }
        }
    }
    private func download(_ resource: ChatResource, message: String) {
        guard let controller, let queue = controller.runtime.transfers, let media = controller.runtime.media else {
            return
        }
        let id = beginOperation()
        task = Task { [weak self] in
            guard let self else { return }
            defer { finishOperation(id) }
            do {
                let resourceID = try await queue.download(resource, message: message)
                try Task.checkCancellation()
                let url = try await media.lease(resourceID)
                guard !Task.isCancelled, taskID == id, controller.runtime.transfers === queue else {
                    try? await media.release(url); return
                }
                lease = url; leaseMedia = media
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.delegate = self
                controller.present(preview, animated: true)
            } catch {
                if !Task.isCancelled, taskID == id { controller.showFailure() }
            }
        }
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { lease == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        lease! as NSURL
    }
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if let lease {
            let media = leaseMedia
            Task { try? await media?.release(lease) }
        }
        lease = nil; leaseMedia = nil
    }
    private func beginOperation() -> UUID {
        task?.cancel()
        let id = UUID(); taskID = id
        return id
    }
    private func finishOperation(_ id: UUID) {
        guard taskID == id else { return }
        task = nil; taskID = nil
    }
    /// 页面或账号结束时停止操作并释放当前预览租约；迟到结果不能再呈现。
    func stop() {
        task?.cancel(); task = nil; taskID = nil
        timer?.cancel(); timer = nil
        recorder?.stop(); player?.stop()
        if let recordingURL, let media = recordingMedia { Task { try? await media.release(recordingURL) } }
        recordingURL = nil; recordingMedia = nil
        if let lease, let media = leaseMedia { Task { try? await media.release(lease) } }
        lease = nil; leaseMedia = nil
    }
    isolated deinit { stop() }
}
