import AzureFishStorage
import AzureFishAPI
import AzureFishChat
import Foundation

/// 将页面草稿转换为存储值；调用前资源必须已导入账号加密存储。
extension ChatDraftSnapshot {
    nonisolated func storageValue() throws -> StoredChatDraft {
        .init(version: version, revision: revision, conversationID: conversationID,
            segments: segments.map { segment in
                switch segment {
                case .text(let text): .text(text)
                case .richText(let text): .richText(text.runs.map { .init(text: $0.text, style: UInt32(truncatingIfNeeded: $0.style.rawValue)) })
                case .attachment(let id): .attachment(id)
                }
            }, documents: try documents.map { try $0.storageValue() },
            media: try media.map { try $0.storageValue() }, audio: try audio.map { try $0.storageValue() })
    }
    nonisolated init(storage value: StoredChatDraft) throws {
        guard value.version == 1 else { throw ChatStoreError.incompatibleSchema }
        self.init(conversationID: value.conversationID)
        version = value.version; revision = value.revision
        segments = value.segments.map {
            switch $0 {
            case .text(let text): .text(text)
            case .richText(let runs): .richText(.init(runs: runs.map { .init($0.text, style: .init(rawValue: Int($0.style))) }))
            case .attachment(let id): .attachment(id)
            }
        }
        documents = try value.documents.map { try Attachment(storage: $0) }
        media = value.media.map { MediaGroupAttachment(storage: $0) }
        audio = value.audio.map { AudioAttachment(storage: $0) }
    }
}

private nonisolated func resourceID(_ url: URL) throws -> UUID {
    guard url.scheme == "azurefish-media", let id = url.host.flatMap(UUID.init(uuidString:)) else { throw ChatMediaStoreError.invalidResource }
    return id
}
private nonisolated func resourceURL(_ id: UUID) -> URL {
    URL(string: "azurefish-media://" + id.uuidString.lowercased())!
}

private extension AudioAttachment {
    nonisolated func storageValue() throws -> StoredDraftAudio {
        .init(id: id, resourceID: try resourceID(fileURL), duration: duration, waveform: waveform, transcript: transcript)
    }
    nonisolated init(storage: StoredDraftAudio) {
        self.init(id: storage.id, fileURL: resourceURL(storage.resourceID), duration: storage.duration,
                  waveform: storage.waveform, transcript: storage.transcript)
    }
}
private extension MediaGroupAttachment {
    nonisolated func storageValue() throws -> StoredDraftMediaGroup {
        .init(id: id, items: try items.map {
            .init(id: $0.id, assetIdentifier: $0.assetIdentifier, originalID: try resourceID($0.originalFileURL),
                thumbnailID: try resourceID($0.thumbnailFileURL), pairedVideoID: try $0.livePhotoVideoURL.map(resourceID),
                width: $0.pixelSize.width, height: $0.pixelSize.height, duration: $0.kind.duration, animated: $0.isAnimatedImage)
        })
    }
    nonisolated init(storage: StoredDraftMediaGroup) {
        self.init(id: storage.id, items: storage.items.map {
            .init(id: $0.id, assetIdentifier: $0.assetIdentifier, originalFileURL: resourceURL($0.originalID),
                  thumbnailFileURL: resourceURL($0.thumbnailID), pixelSize: .init(width: $0.width, height: $0.height),
                  kind: $0.duration.map { .video(duration: $0) } ?? .image, isAnimatedImage: $0.animated,
                  livePhotoVideoURL: $0.pairedVideoID.map(resourceURL))
        })
    }
}
private extension Attachment {
    nonisolated func storageValue() throws -> StoredDraftAttachment {
        switch self {
        case .audio(let v): return .audio(try v.storageValue())
        case .mediaGroup(let v): return .mediaGroup(try v.storageValue())
        case .file(let v): return .file(.init(id: v.id, resourceID: try resourceID(v.fileURL), displayName: v.displayName,
            typeIdentifier: v.typeIdentifier, byteCount: v.byteCount, thumbnailID: try v.thumbnailURL.map(resourceID)))
        case .link(let v): return .link(.init(id: v.id, url: v.url.absoluteString, title: v.title,
            imageID: try v.imageURL.map(resourceID), iconID: try v.iconURL.map(resourceID)))
        }
    }
    nonisolated init(storage: StoredDraftAttachment) throws {
        switch storage {
        case .audio(let v): self = .audio(.init(storage: v))
        case .mediaGroup(let v): self = .mediaGroup(.init(storage: v))
        case .file(let v): self = .file(.init(id: v.id, fileURL: resourceURL(v.resourceID), displayName: v.displayName,
            typeIdentifier: v.typeIdentifier, byteCount: v.byteCount, thumbnailURL: v.thumbnailID.map(resourceURL)))
        case .link(let v):
            guard let url = URL(string: v.url) else { throw ChatMediaStoreError.invalidResource }
            self = .link(.init(id: v.id, url: url, title: v.title, imageURL: v.imageID.map(resourceURL), iconURL: v.iconID.map(resourceURL)))
        }
    }
}
