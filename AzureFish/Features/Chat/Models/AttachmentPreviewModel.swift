import Foundation
import UniformTypeIdentifiers

/// 一次附件浏览的值类型请求；界面来源通过稳定身份延迟解析。
nonisolated struct AttachmentPreviewRequest: Sendable {
    /// 打开预览的业务来源。
    enum Source: Sendable, Equatable {
        case message(Int)
        case documentDraft(UUID)
        case photoDraft(UUID)
    }
    /// 页面拥有的附件原件。
    let attachment: Attachment
    /// 第一次展示的媒体索引。
    var initialIndex: Int = 0
    /// 用于重新定位来源卡片的稳定身份。
    let source: Source
}

/// 已解析的只读预览项目，不包含视图或播放器。
nonisolated struct AttachmentPreviewItem: Sendable {
    /// 原生自定义内容及系统兼容内容的渲染类型。
    enum Kind: Sendable, Equatable {
        case image, video, audio, pdf, text(String), quickLook, unavailable
    }
    let id: UUID
    let url: URL
    let thumbnailURL: URL?
    let title: String
    let kind: Kind
    let livePhotoVideoURL: URL?
    var isLivePhoto: Bool { kind == .image && livePhotoVideoURL != nil }

    init(id: UUID, url: URL, thumbnailURL: URL?, title: String, kind: Kind, livePhotoVideoURL: URL? = nil) {
        self.id = id
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.title = title
        self.kind = kind
        self.livePhotoVideoURL = livePhotoVideoURL
    }

    /// 在后台解析文件类型和有限大小文本，避免在主线程读取原件。
    static func prepare(_ attachment: Attachment) -> [Self] {
        switch attachment {
        case .mediaGroup(let group):
            return group.items.map {
                Self(id: $0.id, url: $0.originalFileURL, thumbnailURL: $0.thumbnailFileURL,
                     title: "",
                     kind: FileManager.default.isReadableFile(atPath: $0.originalFileURL.path)
                        ? ($0.kind.isVideo ? .video : .image) : .unavailable,
                     livePhotoVideoURL: $0.livePhotoVideoURL)
            }
        case .file(let file):
            return [Self(id: file.id, url: file.fileURL, thumbnailURL: file.thumbnailURL,
                         title: file.displayName, kind: fileKind(url: file.fileURL, typeIdentifier: file.typeIdentifier))]
        case .audio, .link:
            return []
        }
    }

    /// 根据真实 UTType 分类；无法安全解码的文本保留系统兼容预览。
    static func fileKind(url: URL, typeIdentifier: String) -> Kind {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .unavailable }
        guard let type = UTType(typeIdentifier) else { return .quickLook }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .plainText) {
            // Use the actual size, not attachment metadata, and cap the read itself.
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
            defer { try? handle.close() }
            let limit = 5 * 1024 * 1024
            guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return .quickLook }
            if let text = String(data: data, encoding: .utf8), !text.contains("\0") { return .text(text) }
            let prefix = Array(data.prefix(2))
            if prefix == [0xFF, 0xFE] || prefix == [0xFE, 0xFF],
               let text = String(data: data, encoding: .utf16) { return .text(text) }
            return .quickLook
        }
        return .quickLook
    }
}

/// 可独立验证的分页和交互关闭规则。
nonisolated enum AttachmentPreviewPolicy {
    static func index(_ index: Int, count: Int) -> Int { min(max(0, index), max(0, count - 1)) }
    static func shouldDismiss(distance: CGFloat, velocity: CGFloat, height: CGFloat) -> Bool {
        distance > max(1, height) * 0.22 || (distance > 24 && velocity > 900)
    }
}
