import Foundation
import CoreGraphics
import CryptoKit

/// 时间线只持有可展示元数据和预览文件，不假定远程原件已在本地。
nonisolated struct RemoteAttachment: Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let messageID: String
    let kind: String
    var items: [MediaThumbnailItem]
    let filename: String
    let byteCount: Int64
    let duration: TimeInterval
    var waveform: [Float] = []
    var transcript: String? = nil
    /// 非 UUID 的隔离测试身份也保持确定性，不为每次渲染生成新身份。
    static func identity(_ value: String) -> UUID {
        if let id = UUID(uuidString: value) { return id }
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    var isMediaGroup: Bool { kind == "media_group" }
}

/// 图片卡片的只读展示输入，原件下载与播放由会话入口负责。
nonisolated struct MediaThumbnailItem: Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let thumbnailFileURL: URL?
    let pixelSize: CGSize
    let kind: MediaKind
    let isAnimatedImage: Bool
    let isLivePhoto: Bool
    var showsAnimatedBadge: Bool { isAnimatedImage || isLivePhoto }
    init(_ item: MediaItem) {
        id = item.id; thumbnailFileURL = item.thumbnailFileURL; pixelSize = item.pixelSize
        kind = item.kind; isAnimatedImage = item.isAnimatedImage; isLivePhoto = item.isLivePhoto
    }
    init(id: UUID, thumbnailFileURL: URL?, pixelSize: CGSize, kind: MediaKind,
         isAnimatedImage: Bool, isLivePhoto: Bool) {
        self.id = id; self.thumbnailFileURL = thumbnailFileURL; self.pixelSize = pixelSize
        self.kind = kind; self.isAnimatedImage = isAnimatedImage; self.isLivePhoto = isLivePhoto
    }
}

nonisolated struct MediaGroupPresentation: Equatable, Hashable, Sendable {
    let id: UUID
    let items: [MediaThumbnailItem]
    init(_ group: MediaGroupAttachment) { id = group.id; items = group.items.map(MediaThumbnailItem.init) }
    init(_ remote: RemoteAttachment) { id = remote.id; items = remote.items }
}

extension Attachment {
    var mediaPresentation: MediaGroupPresentation? {
        switch self {
        case .mediaGroup(let group): .init(group)
        case .remote(let remote) where remote.isMediaGroup: .init(remote)
        default: nil
        }
    }
}
