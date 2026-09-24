//
//  MediaAttachment.swift
//  Demo
//

import Foundation
import CoreGraphics

/// 照片消息中单个媒体项目的类型专属元数据。
nonisolated enum MediaKind: Codable, Equatable, Hashable, Sendable {
    /// 静态或以静态缩略图呈现的图像媒体。
    case image
    /// 包含以秒计的有效时长的视频媒体。
    case video(duration: TimeInterval)

    /// 视频时长，单位为秒；图像媒体返回 `nil`。
    var duration: TimeInterval? {
        guard case .video(let duration) = self else { return nil }
        return duration
    }

    /// 指示当前媒体是否为视频的布尔值。
    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

/// 已导入页面附件目录、可以进入照片消息的单个媒体项目。
///
/// 草稿持久化保留身份、像素尺寸及动态媒体类型，并将所有本地资源映射为独立副本。
/// 恢复到页面前须重新映射文件 URL；Live Photo 原件与配对视频共同组成一个完整条目。
nonisolated struct MediaItem: Codable, Equatable, Hashable, Sendable,
    Identifiable {
    /// 媒体项目的稳定标识符，与照片库资源身份分离。
    let id: UUID
    /// 照片选择器提供的资源标识符；非照片库来源可为 `nil`。
    let assetIdentifier: String?
    /// 页面拥有的媒体原件 URL。
    let originalFileURL: URL
    /// 页面生成的静态缩略图 URL。
    let thumbnailFileURL: URL
    /// 用于计算展示宽高比的媒体像素尺寸。
    let pixelSize: CGSize
    /// 媒体类型及视频专属时长信息。
    let kind: MediaKind
    /// 图片原文件是否包含多个动画帧，不包含仅具有配对视频的实况照片。
    let isAnimatedImage: Bool
    /// 与原始照片匹配、由页面拥有的实况视频资源。
    let livePhotoVideoURL: URL?
    /// 只有图像和配对视频共同存在于模型中才具有实况身份。
    var isLivePhoto: Bool { !kind.isVideo && livePhotoVideoURL != nil }
    /// 草稿原有动态角标同时覆盖多帧图片和实况照片。
    var showsAnimatedBadge: Bool { isAnimatedImage || isLivePhoto }

    /// 使用已导入的原件、缩略图与元数据创建媒体项目。
    ///
    /// - Parameters:
    ///   - id: 项目的稳定标识符，默认生成新身份。
    ///   - assetIdentifier: 可选的照片库资源标识符。
    ///   - originalFileURL: 页面拥有的原件 URL。
    ///   - thumbnailFileURL: 静态缩略图 URL。
    ///   - pixelSize: 用于展示比例计算的像素尺寸。
    ///   - kind: 图像或包含时长的视频类型。
    ///   - isAnimatedImage: 原始图片是否包含多帧，默认值为 `false`。
    ///   - livePhotoVideoURL: 与原始照片配对的实况视频，普通图片为 `nil`。
    init(
        id: UUID = UUID(),
        assetIdentifier: String?,
        originalFileURL: URL,
        thumbnailFileURL: URL,
        pixelSize: CGSize,
        kind: MediaKind,
        isAnimatedImage: Bool = false,
        livePhotoVideoURL: URL? = nil
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.originalFileURL = originalFileURL
        self.thumbnailFileURL = thumbnailFileURL
        self.pixelSize = pixelSize
        self.kind = kind
        self.isAnimatedImage = isAnimatedImage
        self.livePhotoVideoURL = kind.isVideo ? nil : livePhotoVideoURL
    }
}

/// 一次选择并发送的有序照片和视频集合。
nonisolated struct MediaGroupAttachment:
    Codable, Equatable,
    Hashable,
    Sendable {
    /// 系统照片选择器单次允许选择的最大项目数量。
    static let selectionLimit = 20

    /// 整组附件的稳定标识符。
    let id: UUID
    /// 按用户选择顺序排列的媒体项目。
    let items: [MediaItem]

    /// 创建保留指定项目顺序的媒体组；省略标识符时生成新身份。
    init(id: UUID = UUID(), items: [MediaItem]) {
        self.id = id
        self.items = items
    }

    /// 按媒体项目顺序返回原件与缩略图 URL，供页面存储统一管理。
    var localFileURLs: [URL] {
        items.flatMap { [$0.originalFileURL, $0.thumbnailFileURL] + [$0.livePhotoVideoURL].compactMap { $0 } }
    }
}

/// 照片选择器中仍在导入或已经就绪的单项展示状态。
nonisolated enum MediaDraftItemContent: Equatable, Sendable {
    /// 原始文件或媒体元数据仍在导入。
    case importing
    /// 媒体原件和元数据已经就绪，可参与发送。
    case ready(MediaItem)
}

/// 单个媒体草稿的稳定身份、照片资源引用与展示内容。
nonisolated struct MediaDraftItemPresentation:
    Equatable,
    Sendable,
    Identifiable {
    /// 草稿项目从导入占位到就绪状态保持不变的标识符。
    let id: UUID
    /// 关联照片库项目的资源标识符；不可用时为 `nil`。
    let assetIdentifier: String?
    /// 当前项目的导入占位或已就绪内容。
    let content: MediaDraftItemContent

    /// 选择时已知的展示比例；可来自 provider 的点尺寸，不要求是原件像素尺寸。
    let initialDisplaySize: CGSize?
    /// 媒体尺寸未知时，保留导入状态，等待正确比例后再插入卡片。
    let waitsForDisplaySize: Bool

    init(id: UUID, assetIdentifier: String?, content: MediaDraftItemContent,
         initialDisplaySize: CGSize? = nil, waitsForDisplaySize: Bool = false) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.content = content
        self.initialDisplaySize = initialDisplaySize
        self.waitsForDisplaySize = waitsForDisplaySize
    }

    var isReadyForDisplay: Bool { !waitsForDisplaySize || displaySize != nil }
    var displaySize: CGSize? { mediaItem?.pixelSize ?? initialDisplaySize }

    /// 已经导入的媒体项目；仍在导入时为 `nil`。
    var mediaItem: MediaItem? {
        guard case .ready(let item) = content else { return nil }
        return item
    }
}

/// Composer 渲染的有序媒体草稿，不持有系统选择器或媒体框架对象。
nonisolated struct MediaDraftPresentation: Equatable, Sendable {
    /// 当前有序媒体草稿所属的附件组标识符。
    let groupID: UUID
    /// 按用户选择顺序排列的媒体草稿项目。
    let items: [MediaDraftItemPresentation]

    var visibleItems: [MediaDraftItemPresentation] { items.filter(\.isReadyForDisplay) }
    var hasVisibleItems: Bool { items.contains(where: \.isReadyForDisplay) }

    /// 指示草稿非空且全部项目已完成导入的布尔值。
    var canSend: Bool {
        !items.isEmpty && items.allSatisfy { $0.mediaItem != nil }
    }

    /// 可以发送的有序媒体组；任一项目未就绪或集合为空时为 `nil`。
    var attachment: MediaGroupAttachment? {
        guard canSend else { return nil }
        return MediaGroupAttachment(
            id: groupID,
            items: items.compactMap(\.mediaItem)
        )
    }
}
