//
//  Attachment.swift
//  Demo
//

import Foundation

/// 文件草稿与消息共享值模型；录音转换后不再携带录音会话或波形状态。
nonisolated struct FileAttachment: Codable, Equatable, Hashable, Sendable {
    /// 文件附件的稳定标识符。
    let id: UUID
    /// 页面拥有的文件原件 URL。
    let fileURL: URL
    /// 卡片展示及系统导出时使用的文件名称。
    let displayName: String
    /// 文件内容的统一类型标识符。
    let typeIdentifier: String
    /// 文件大小，单位为字节。
    let byteCount: Int64
    /// 可选的本地文件缩略图 URL；尚未生成或不支持时为 `nil`。
    var thumbnailURL: URL? = nil
}

/// 网页元数据失败时仍可按原始 URL 发送，不伪造应用协作身份。
nonisolated struct LinkAttachment: Codable, Equatable, Hashable, Sendable {
    /// 链接附件的稳定标识符，默认生成新身份。
    var id = UUID()
    /// 用户输入或粘贴的原始网页 URL。
    let url: URL
    /// 系统元数据提供的网页标题；尚未取得时为 `nil`。
    var title: String? = nil
    /// 保存在页面目录的网页封面 URL；无封面时为 `nil`。
    var imageURL: URL? = nil
    /// 网站图标单独保存，避免被当作封面放大。
    var iconURL: URL? = nil

    /// 返回 URL 是否包含非空主机名且使用 HTTP 或 HTTPS 协议。
    static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty
    }
}

/// 聊天消息可以携带的页面级本地附件。
///
/// 附件枚举是消息层与具体媒体实现之间的值类型边界。音频、媒体组、文件与链接
/// 由各自的值模型描述，时间线渲染层按类型选择单元格。模型仅保存身份、元数据和
/// 本地 URL，不持有图像视图、资源选择器结果或播放器。
/// 持久化草稿时由快照统一映射本地 URL，清单仅引用草稿存储拥有的相对路径。
nonisolated enum Attachment: Codable, Equatable, Hashable, Sendable {
    /// 包含本地录音或文本合成语音的音频附件。
    case audio(AudioAttachment)

    /// 一次有序选择产生的图片和视频媒体组。
    case mediaGroup(MediaGroupAttachment)
    /// 可内联展示并通过系统文件选择器导出的本地文件。
    case file(FileAttachment)
    /// 保留原始 URL 与可选缓存元数据的网页链接。
    case link(LinkAttachment)

    /// 附件的稳定标识符。
    var id: UUID {
        switch self {
        case .audio(let attachment):
            attachment.id
        case .mediaGroup(let attachment):
            attachment.id
        case .file(let attachment): attachment.id
        case .link(let attachment): attachment.id
        }
    }

    /// 附件在页面生命周期内拥有的全部本地文件。
    ///
    /// 页面附件存储使用此集合统一清理资源。媒体组包含原件与缩略图，文件包含
    /// 原件与可选缩略图，链接仅包含已缓存的封面与站点图标，不包含远程网页 URL。
    var localFileURLs: [URL] {
        switch self {
        case .audio(let attachment):
            [attachment.fileURL]
        case .mediaGroup(let attachment):
            attachment.localFileURLs
        case .file(let file): [file.fileURL] + [file.thumbnailURL].compactMap { $0 }
        case .link(let link): [link.imageURL, link.iconURL].compactMap { $0 }
        }
    }

    /// 音频载荷；附件不是音频时为 `nil`。
    var audio: AudioAttachment? {
        guard case .audio(let attachment) = self else { return nil }
        return attachment
    }

    /// 图片/视频媒体组；附件不是媒体组时为 `nil`。
    var mediaGroup: MediaGroupAttachment? {
        guard case .mediaGroup(let attachment) = self else { return nil }
        return attachment
    }
}

/// 提供基于已提交附件生成同类型模拟回复的值转换。
extension Attachment {
    /// 模拟回复使用独立消息/附件/媒体项目身份，共享页面已提交的只读资源。
    /// 已提交资源统一保留到页面退出，因此无须复制视频，也不会被 Composer 草稿清理。
    func simulatedReply() -> Self {
        switch self {
        case .audio(let audio):
            return .audio(.init(fileURL: audio.fileURL, duration: audio.duration,
                                waveform: audio.waveform, transcript: audio.transcript))
        case .mediaGroup(let group):
            return .mediaGroup(.init(items: group.items.map { item in
                .init(assetIdentifier: item.assetIdentifier, originalFileURL: item.originalFileURL,
                      thumbnailFileURL: item.thumbnailFileURL, pixelSize: item.pixelSize,
                      kind: item.kind, isAnimatedImage: item.isAnimatedImage, livePhotoVideoURL: item.livePhotoVideoURL)
            }))
        case .file(let file):
            return .file(.init(id: UUID(), fileURL: file.fileURL, displayName: file.displayName,
                               typeIdentifier: file.typeIdentifier, byteCount: file.byteCount,
                               thumbnailURL: file.thumbnailURL))
        case .link(var link):
            link.id = UUID()
            return .link(link)
        }
    }
}
