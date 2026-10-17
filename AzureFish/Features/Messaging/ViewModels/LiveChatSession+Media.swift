import AzureFishStorage
import AVFoundation
import AzureFishAPI
import AzureFishChat
import UniformTypeIdentifiers
import UIKit

@available(iOS 26.0, *)
extension LiveChatSession {
    /// 最多并行准备两条消息，缓存完成后复用原版卡片、播放器与附件转场。
    func scheduleMedia() {
        guard !stopped, let controller, let drafts = runtime.originalDraftStore else { return }
        let visibleKeys = Set(controller.conversationView.visibleMessageIDs.compactMap { sourceIDs[$0] })
        for (key, task) in mediaTasks where !visibleKeys.contains(key) { task.cancel() }
        let keys = messages.reversed().filter { !$0.revoked && $0.isKnownContent && !$0.assets.isEmpty }.map(\.id)
            + uploads.map { $0.messageID.uuidString.lowercased() }
            + pending.filter { $0.outgoing.kind != "text" }.map { $0.outgoing.id.uuidString.lowercased() }
        for key in keys where visibleKeys.contains(key) && contents[key] == nil && mediaTasks[key] == nil && !mediaFailures.contains(key) {
            guard mediaTasks.count < 2 else { break }
            let release = (controller.attachmentStore as? PageAttachmentStore)?.acquireFileLease()
            mediaTasks[key] = Task { [weak self] in
                defer { release?() }
                guard let self else { return }
                defer { mediaTasks[key] = nil; scheduleMedia() }
                do {
                    let files = PageAttachmentStore(parentDirectory: controller.attachmentStore.directoryURL)
                    var installed = false
                    defer { if !installed { files.removeAll() } }
                    var restored = false
                    var attachment: Attachment?
                    if !messages.contains(where: { $0.id == key && !$0.assets.isEmpty }), let stored = try await drafts.store.presentation(message: key) {
                        let saved = try ChatDraftSnapshot(storage: stored)
                        attachment = try await drafts.materialize(saved, into: files.directoryURL).snapshot?.documents.first
                        restored = attachment != nil
                    }
                    if attachment == nil, let message = messages.first(where: { $0.id == key && !$0.revoked }) {
                        attachment = try await resolvePreview(message, files: files)
                    }
                    if attachment == nil, let batch = uploads.first(where: { $0.messageID.uuidString.lowercased() == key }) {
                        attachment = try await resolve(batch, files: files)
                    }
                    guard let attachment else { throw ChatMediaStoreError.unavailable }
                    try Task.checkCancellation()
                    guard !stopped, !messages.contains(where: { $0.id == key && $0.revoked }) else { return }
                    if !restored, case .remote = attachment {}
                    else if !restored { try await cache(attachment, key: key, drafts: drafts) }
                    try Task.checkCancellation()
                    guard !stopped, !messages.contains(where: { $0.id == key && $0.revoked }) else { return }
                    files.registerCommitted(attachment)
                    mediaStores[key] = files
                    installed = true
                    contents[key] = .attachment(attachment)
                    refresh()
                } catch is CancellationError {} catch {
                    mediaFailures.insert(key)
                    refresh()
                }
            }
        }
    }
    func remoteMetadata(_ message: ChatMessage, thumbnails: [String: URL] = [:]) -> RemoteAttachment {
        let source = message.assets.flatMap(\.resources).first { $0.role == "original" }
        return RemoteAttachment(id: RemoteAttachment.identity(message.id), messageID: message.id, kind: message.kind,
            items: message.assets.map { asset in
                MediaThumbnailItem(id: RemoteAttachment.identity(asset.id), thumbnailFileURL: thumbnails[asset.id],
                    pixelSize: CGSize(width: Int(asset.width), height: Int(asset.height)),
                    kind: asset.kind == "video" ? .video(duration: Double(asset.duration) / 1000) : .image,
                    isAnimatedImage: asset.animated, isLivePhoto: asset.kind == "live_photo")
            }, filename: source?.filename ?? "", byteCount: source?.bytes ?? 0,
            duration: Double(message.assets.first?.duration ?? 0) / 1000, waveform: message.assets.first?.waveform ?? [])
    }
    /// 列表只下载服务器已生成的缩略图或封面；没有预览的文件和音频保留元数据。
    func resolvePreview(_ message: ChatMessage, files: any AttachmentStoring) async throws -> Attachment {
        guard let transfers = runtime.transfers, let media = runtime.media else { throw ChatMediaStoreError.unavailable }
        var thumbnails: [String: URL] = [:]
        for asset in message.assets where message.kind == "media_group" {
            guard let resource = asset.resources.first(where: { ["thumbnail", "cover"].contains($0.role) }) else { continue }
            let id = try await transfers.download(resource, message: message.id)
            let lease = try await media.lease(id)
            do {
                thumbnails[asset.id] = try files.importFile(at: lease, prefix: "received-preview", pathExtension: lease.pathExtension)
                try await media.release(lease)
            } catch { try? await media.release(lease); throw error }
        }
        var remote = remoteMetadata(message, thumbnails: thumbnails)
        remote.transcript = try await runtime.engine?.store.transcript(message: message.id)
        return .remote(remote)
    }
    /// 进入预览、播放或导出前重新检查消息终态及授权，解析真正的本地原件。
    func resolveAttachment(_ attachment: Attachment, messageID: Int) async throws -> Attachment {
        guard let key = sourceIDs[messageID], let engine = runtime.engine, !stopped else { throw CancellationError() }
        guard let message = try await engine.store.visibleMessage(key, conversation: conversation.id) else {
            // 尚未发送的本机附件由页面持有。
            guard !messages.contains(where: { $0.id == key }) else { throw ChatMediaStoreError.unavailable }
            return attachment
        }
        guard !message.revoked, message.isKnownContent else { throw ChatMediaStoreError.unavailable }
        if message.assets.isEmpty { return attachment }
        var requested = message
        if case .remote(let remote) = attachment, remote.isMediaGroup {
            let ids = Set(remote.items.map { $0.id.uuidString.lowercased() })
            requested.assets = message.assets.filter { ids.contains($0.id.lowercased()) }
            guard !requested.assets.isEmpty else { throw ChatMediaStoreError.invalidResource }
        }
        let files = PageAttachmentStore(parentDirectory: controller?.attachmentStore.directoryURL)
        var installed = false
        defer { if !installed { files.removeAll() } }
        let resolved = try await resolve(requested, files: files)
        try Task.checkCancellation()
        guard !stopped, runtime.engine === engine,
              let current = try await engine.store.visibleMessage(key, conversation: conversation.id), !current.revoked else { throw CancellationError() }
        files.registerCommitted(resolved)
        mediaStores[key + ":original:" + UUID().uuidString] = files
        installed = true
        if message.kind == "audio" || message.kind == "file" { contents[key] = .attachment(resolved); refresh() }
        return resolved
    }
    func resolve(_ message: ChatMessage, files: any AttachmentStoring) async throws -> Attachment {
        guard let transfers = runtime.transfers, let media = runtime.media else { throw ChatMediaStoreError.unavailable }
        let id = UUID(uuidString: message.id) ?? UUID()
        if message.kind == "link", let url = URL(string: message.linkURL ?? message.text) {
            return .link(await AccountLinkPreview.load(.init(id: id, url: url), files: files))
        }
        var items: [MediaItem] = []
        for asset in message.assets {
            var urls: [String: URL] = [:]
            for resource in asset.resources where ["original", "paired_video", "thumbnail", "cover"].contains(resource.role) {
                let resourceID = try await transfers.download(resource, message: message.id)
                let lease = try await media.lease(resourceID)
                do {
                    urls[resource.role] = try files.importFile(at: lease, prefix: "received", pathExtension: lease.pathExtension)
                    try await media.release(lease)
                } catch { try? await media.release(lease); throw error }
            }
            guard let original = urls["original"], let resource = asset.resources.first(where: { $0.role == "original" }) else {
                throw ChatMediaStoreError.invalidResource
            }
            if message.kind == "file" {
                return .file(.init(id: id, fileURL: original, displayName: resource.filename,
                    typeIdentifier: UTType(mimeType: resource.mime)?.identifier ?? UTType.data.identifier, byteCount: resource.bytes))
            }
            if message.kind == "audio" {
                let transcript: String? = try await runtime.engine?.store.transcript(message: message.id)
                return .audio(.init(id: id, fileURL: original, duration: Double(asset.duration) / 1000,
                    waveform: asset.waveform, transcript: transcript))
            }
            let thumbnail: URL
            if let preview = urls["thumbnail"] ?? urls["cover"] { thumbnail = preview }
            else {
                thumbnail = files.makeFileURL(prefix: "received-thumbnail", pathExtension: "jpg")
                _ = try await MediaImportProcessor.makeMetadata(originalURL: original, thumbnailURL: thumbnail, isVideo: asset.kind == "video")
            }
            if asset.kind == "live_photo", urls["paired_video"] == nil { throw ChatMediaStoreError.invalidResource }
            items.append(.init(id: UUID(uuidString: asset.id) ?? UUID(), assetIdentifier: nil, originalFileURL: original,
                thumbnailFileURL: thumbnail, pixelSize: CGSize(width: Int(asset.width), height: Int(asset.height)),
                kind: asset.kind == "video" ? .video(duration: Double(asset.duration) / 1000) : .image,
                isAnimatedImage: asset.animated, livePhotoVideoURL: urls["paired_video"]))
        }
        guard !items.isEmpty else { throw ChatMediaStoreError.invalidResource }
        return .mediaGroup(.init(id: id, items: items))
    }
    /// 恢复旧版附件任务时仍从账号加密资源创建受保护的页面副本。
    func resolve(_ batch: ChatUploadBatch, files: any AttachmentStoring) async throws -> Attachment {
        guard let media = runtime.media else { throw ChatMediaStoreError.unavailable }
        var items: [MediaItem] = []
        for item in batch.items {
            var urls: [String: URL] = [:]
            for resource in item.resources {
                let lease = try await media.lease(resource.id)
                do {
                    urls[resource.input.role] = try files.importFile(at: lease, prefix: "pending", pathExtension: lease.pathExtension)
                    try await media.release(lease)
                } catch { try? await media.release(lease); throw error }
            }
            guard let original = urls["original"], let source = item.resources.first(where: { $0.input.role == "original" }) else { throw ChatMediaStoreError.invalidResource }
            if batch.kind == "file" {
                return .file(.init(id: batch.messageID, fileURL: original, displayName: source.input.filename,
                    typeIdentifier: UTType(mimeType: source.input.mime)?.identifier ?? UTType.data.identifier, byteCount: source.input.bytes))
            }
            if batch.kind == "audio" {
                let duration = try await AVURLAsset(url: original).load(.duration).seconds
                return .audio(.init(id: batch.messageID, fileURL: original, duration: duration, waveform: []))
            }
            let thumbnail = files.makeFileURL(prefix: "pending-thumbnail", pathExtension: "jpg")
            let metadata = try await MediaImportProcessor.makeMetadata(originalURL: original, thumbnailURL: thumbnail, isVideo: item.kind == "video")
            if item.kind == "live_photo", urls["paired_video"] == nil { throw ChatMediaStoreError.invalidResource }
            items.append(.init(id: item.id, assetIdentifier: nil, originalFileURL: original, thumbnailFileURL: thumbnail,
                pixelSize: metadata.pixelSize, kind: metadata.kind, isAnimatedImage: metadata.isAnimatedImage, livePhotoVideoURL: urls["paired_video"]))
        }
        return .mediaGroup(.init(id: batch.messageID, items: items))
    }
    func didTranscribe(_ text: String, messageID: Int, attachmentID: UUID) {
        guard let key = sourceIDs[messageID], !stopped,
              !messages.contains(where: { $0.id == key && $0.revoked }),
              case .attachment(.audio(var audio)) = contents[key], audio.id == attachmentID else { return }
        audio.transcript = text
        contents[key] = .attachment(.audio(audio))
        if let drafts = runtime.originalDraftStore {
            perform { [self] in
                try await drafts.store.saveTranscript(text, message: key)
                try await cache(.audio(audio), key: key, drafts: drafts)
            }
        }
    }
    func evict(_ key: String) {
        mediaTasks.removeValue(forKey: key)?.cancel()
        for storedKey in mediaStores.keys.filter({ $0 == key || $0.hasPrefix(key + ":original:") }) {
            mediaStores.removeValue(forKey: storedKey)?.removeAll()
        }
        if case .attachment(let attachment) = contents.removeValue(forKey: key) {
            if let id = identities[key] {
                controller?.audioTranscription.cancel(messageID: id)
                if controller?.audioController.playbackState.messageID == id { controller?.audioController.stopPlayback() }
                if controller?.attachmentPreviewSource == .message(id) {
                    controller?.attachmentPreviewTask?.cancel()
                    controller?.attachmentPreviewController?.dismiss(animated: false)
                }
            }
            attachment.localFileURLs.forEach { controller?.attachmentStore.removeFile(at: $0) }
            if let directory = controller?.attachmentStore.directoryURL {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("exports/" + attachment.id.uuidString))
            }
        }
    }
}
