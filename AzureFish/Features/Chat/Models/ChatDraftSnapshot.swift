import Foundation

/// 单个会话的可持久化草稿，保存正文语义、附件身份和已就绪资源。
///
/// 不归档 UIKit 对象、编辑器临时属性、播放进度或导入状态。
/// 页面中的文件 URL 指向页面副本，磁盘清单中的文件 URL 则相对于会话目录。
nonisolated struct ChatDraftSnapshot: Codable, Equatable, Sendable {
    /// 清单结构版本；当前仅支持版本 1，与保存次数无关。
    var version = 1
    /// 当前清单的保存修订号；由磁盘存储在提交时递增，页面快照默认使用 0。
    var revision: UInt64 = 0
    /// 草稿所属会话的稳定标识，用于隔离不同聊天的存储目录。
    let conversationID: String
    /// 按编辑器顺序排列的语义片段，保留用户输入的空白、换行和内联附件位置。
    var segments: [DraftSegment] = []
    /// 正文片段引用的已就绪附件，按其在正文中出现的顺序排列。
    var documents: [Attachment] = []
    /// 输入栏中独立展示的有序媒体组；没有已就绪媒体时为 `nil`。
    var media: MediaGroupAttachment?
    /// 已停止录制、尚未发送的独立语音预览；没有预览时为 `nil`。
    var audio: AudioAttachment?

    /// 是否既无正文片段也无附件；仅含用户空白文字的片段仍属于有效草稿。
    var isEmpty: Bool {
        segments.isEmpty && documents.isEmpty && media == nil && audio == nil
    }

    /// 所有附件引用的本地文件 URL，包含原件及预览资源，不包含链接的网页地址。
    var localFileURLs: [URL] {
        documents.flatMap(\.localFileURLs)
            + (media?.localFileURLs ?? []) + (audio.map { [$0.fileURL] } ?? [])
    }

    /// 在文件所有权边界重建值，保留所有附件身份和展示元数据。
    ///
    /// - Parameter transform: 将每个本地文件 URL 转换为目标所有者下的 URL；可执行复制或路径校验。
    /// - Returns: 使用新文件 URL 的快照，正文片段、版本和会话标识保持不变。
    /// - Throws: `transform` 抛出的错误；调用方负责回收转换过程中已经创建的文件。
    func mappingFiles(_ transform: (URL) throws -> URL) rethrows -> Self {
        var value = self
        value.documents = try documents.map { try $0.mappingDraftFiles(transform) }
        value.media = try media.map { try $0.mappingDraftFiles(transform) }
        value.audio = try audio.map { try $0.mappingDraftFiles(transform) }
        return value
    }
}

/// 为语音草稿提供不改变身份及音频元数据的文件映射。
extension AudioAttachment {
    /// 重建语音附件的文件引用，保留时长、波形和转写文字。
    ///
    /// - Parameter transform: 原始语音文件 URL 到目标文件 URL 的转换。
    /// - Returns: 身份和展示信息不变的语音附件副本。
    /// - Throws: 文件转换抛出的错误。
    nonisolated func mappingDraftFiles(_ transform: (URL) throws -> URL) rethrows -> Self {
        .init(id: id, fileURL: try transform(fileURL), duration: duration,
              waveform: waveform, transcript: transcript)
    }
}

/// 为媒体草稿提供原件、缩略图及 Live Photo 配对视频的统一文件映射。
extension MediaItem {
    /// 转换媒体条目的全部本地资源引用，保留像素尺寸、类型和稳定身份。
    ///
    /// - Parameter transform: 对原件、缩略图及存在的配对视频逐一调用的 URL 转换。
    /// - Returns: 引用目标文件的媒体条目，不会把 Live Photo 降级为普通图片。
    /// - Throws: 任一文件转换抛出的错误。
    nonisolated func mappingDraftFiles(_ transform: (URL) throws -> URL) rethrows -> Self {
        .init(id: id, assetIdentifier: assetIdentifier, originalFileURL: try transform(originalFileURL),
              thumbnailFileURL: try transform(thumbnailFileURL), pixelSize: pixelSize, kind: kind,
              isAnimatedImage: isAnimatedImage, livePhotoVideoURL: try livePhotoVideoURL.map(transform))
    }
}

/// 为媒体组草稿提供保持组身份及条目顺序的文件映射。
extension MediaGroupAttachment {
    /// 按原顺序转换媒体组内每个条目的资源引用。
    ///
    /// - Parameter transform: 传递给每个媒体条目的本地文件 URL 转换。
    /// - Returns: 组身份、条目身份和顺序不变的媒体组副本。
    /// - Throws: 任一条目转换抛出的错误。
    nonisolated func mappingDraftFiles(_ transform: (URL) throws -> URL) rethrows -> Self {
        .init(id: id, items: try items.map { try $0.mappingDraftFiles(transform) })
    }
}

/// 为各类内联草稿附件提供统一的本地资源映射入口。
extension Attachment {
    /// 转换附件持有的本地文件引用，链接附件的网页 URL 保持不变。
    ///
    /// - Parameter transform: 用于原件及存在的预览资源的 URL 转换。
    /// - Returns: 类型、身份及展示元数据不变的附件副本。
    /// - Throws: 任一本地文件转换抛出的错误。
    nonisolated func mappingDraftFiles(_ transform: (URL) throws -> URL) rethrows -> Self {
        switch self {
        case .audio(let audio): return .audio(try audio.mappingDraftFiles(transform))
        case .mediaGroup(let group): return .mediaGroup(try group.mappingDraftFiles(transform))
        case .file(let file):
            return .file(.init(id: file.id, fileURL: try transform(file.fileURL), displayName: file.displayName,
                              typeIdentifier: file.typeIdentifier, byteCount: file.byteCount,
                              thumbnailURL: try file.thumbnailURL.map(transform)))
        case .link(var link):
            link.imageURL = try link.imageURL.map(transform)
            link.iconURL = try link.iconURL.map(transform)
            return .link(link)
        }
    }
}
