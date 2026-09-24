//
//  AttachmentStore.swift
//  Demo
//

import Foundation

/// 管理单个聊天页面拥有的附件文件。
///
/// 附件先以草稿身份注册；只有消息成功进入 ViewModel 后才提交。取消草稿会立即
/// 删除其全部文件，已提交的音频、图片和视频附件则保留到页面销毁；资源选择器
/// 返回的临时 URL 永远不会直接保存到消息模型。
@MainActor
protocol AttachmentStoring: AnyObject {
    /// 页面附件目录的位置。
    var directoryURL: URL { get }

    /// 返回位于页面目录中的唯一文件 URL。
    ///
    /// - Parameters:
    ///   - prefix: 便于诊断文件来源的名称前缀。
    ///   - pathExtension: 不包含句点的文件扩展名。
    /// - Returns: 尚未创建文件的唯一 URL。
    func makeFileURL(prefix: String, pathExtension: String) -> URL

    /// 将资源选择器或导出器提供的文件复制到页面目录。
    ///
    /// 调用方在复制完成后使用返回 URL 创建类型专属附件，并通过
    /// ``registerDraft(_:)`` 注册。源文件仍由原提供方管理。
    ///
    /// - Parameters:
    ///   - sourceURL: 由资源选择器、相机或导出会话提供的可读文件。
    ///   - prefix: 便于诊断文件来源的名称前缀。
    ///   - pathExtension: 目标扩展名；传入 `nil` 时沿用源文件扩展名。
    /// - Returns: 页面独立临时目录中的新文件 URL。
    func importFile(
        at sourceURL: URL,
        prefix: String,
        pathExtension: String?
    ) throws -> URL

    /// 注册尚未进入消息时间线的附件草稿。
    func registerDraft(_ attachment: Attachment)

    /// 注册不经过 Composer 预览、但已经由页面拥有的附件。
    ///
    /// 文本合成的 incoming 音频回复使用此入口。附件会保留到页面销毁。
    func registerCommitted(_ attachment: Attachment)

    /// 将草稿转为已提交附件。
    ///
    /// - Parameter id: 草稿附件的稳定标识符。
    /// - Returns: 找到并提交草稿时为 `true`；否则为 `false`。
    func commitDraft(id: UUID) -> Bool

    /// 删除指定草稿及其拥有的全部本地文件。
    func discardDraft(id: UUID)

    /// 删除尚未注册为附件的部分文件。
    func removeFile(at url: URL)

    /// 删除页面拥有的全部附件和临时文件。
    func removeAll()
}

/// 使用独立临时目录实现的页面附件存储。
@MainActor
final class PageAttachmentStore: AttachmentStoring {

    /// 页面注入的缓存失效入口，不延长图片服务生命周期。
    weak var imageLoader: MediaImageLoader?

    /// 当前页面拥有的独立附件目录。
    let directoryURL: URL

    /// 执行附件目录和文件操作的文件管理器。
    private let fileManager: FileManager
    /// 按稳定标识符索引的未提交附件；取消时删除其文件。
    private var drafts: [UUID: Attachment] = [:]
    /// 按稳定标识符索引的已提交附件；文件保留至页面清理。
    private var committed: [UUID: Attachment] = [:]
    /// 仍在使用页面源文件的异步操作数量；非零时延迟物理删除文件。
    private var fileLeaseCount = 0
    /// 租约存续期间收到的单文件删除请求，在最后一个租约释放时处理。
    private var deferredRemovals: Set<URL> = []

    /// 保存任务持有页面文件，删除操作延迟到最后一个任务结束。
    ///
    /// 应在异步文件任务入队前调用，并在任务结束后于主 Actor 释放。
    /// - Returns: 强持有此存储的幂等释放闭包；调用方必须在成功或失败路径上都调用它。
    func acquireFileLease() -> () -> Void {
        fileLeaseCount += 1
        var released = false
        return { [self] in
            guard !released else { return }
            released = true
            fileLeaseCount -= 1
            guard fileLeaseCount == 0 else { return }
            if removedAllFiles {
                try? fileManager.removeItem(at: directoryURL)
            } else {
                deferredRemovals.forEach { try? fileManager.removeItem(at: $0) }
            }
            deferredRemovals.removeAll()
        }
    }

    /// 是否已请求整目录清理；登记立即清空，实际删除可能等待文件租约释放。
    private var removedAllFiles = false

    /// 创建页面附件存储并准备独立目录。
    ///
    /// - Parameters:
    ///   - fileManager: 用于创建、复制和删除附件文件的文件管理器。
    ///   - parentDirectory: 页面目录的父目录；默认使用系统临时目录。
    init(
        fileManager: FileManager = .default,
        parentDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        directoryURL = (parentDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent(
                "Chat-\(UUID().uuidString)",
                isDirectory: true
            )
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    /// 在所属主 Actor 上释放存储，使用同一文件管理器删除页面目录及残留临时文件。
    isolated deinit {
        try? fileManager.removeItem(at: directoryURL)
    }

    /// 返回页面目录内带指定前缀和扩展名的唯一 URL，不创建文件。
    func makeFileURL(prefix: String, pathExtension: String) -> URL {
        directoryURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    /// 将源文件复制到页面目录，并返回由页面拥有的目标 URL。
    ///
    /// `pathExtension` 为 `nil` 时沿用源扩展名；复制失败时向调用方抛出错误。
    func importFile(
        at sourceURL: URL,
        prefix: String,
        pathExtension: String? = nil
    ) throws -> URL {
        let resolvedExtension = pathExtension ?? sourceURL.pathExtension
        let destinationURL: URL
        if resolvedExtension.isEmpty {
            destinationURL = directoryURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)"
            )
        } else {
            destinationURL = makeFileURL(
                prefix: prefix,
                pathExtension: resolvedExtension
            )
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    /// 注册附件草稿，并移除同一身份的已提交记录。
    func registerDraft(_ attachment: Attachment) {
        drafts[attachment.id] = attachment
        committed.removeValue(forKey: attachment.id)
    }

    /// 将附件直接记录为已提交资源，并移除同一身份的草稿记录。
    func registerCommitted(_ attachment: Attachment) {
        drafts.removeValue(forKey: attachment.id)
        committed[attachment.id] = attachment
    }

    /// 将指定草稿转入已提交集合。
    ///
    /// - Returns: 找到并完成转移时为 `true`；草稿不存在时为 `false`。
    func commitDraft(id: UUID) -> Bool {
        guard let attachment = drafts.removeValue(forKey: id) else {
            return false
        }
        committed[id] = attachment
        return true
    }

    /// 移除指定草稿，并删除其登记的全部本地文件。
    func discardDraft(id: UUID) {
        guard let attachment = drafts.removeValue(forKey: id) else { return }
        for url in attachment.localFileURLs {
            removeFile(at: url)
        }
    }

    /// 尝试删除指定本地文件；文件不存在或删除失败时不抛出错误。
    ///
    /// 图片缓存立即失效；存在文件租约时，将磁盘删除延迟到最后一个租约释放。
    func removeFile(at url: URL) {
        imageLoader?.invalidate(url: url)
        if fileLeaseCount > 0 { deferredRemovals.insert(url) }
        else { try? fileManager.removeItem(at: url) }
    }

    /// 清空附件登记并尝试删除页面目录；重复调用不再执行清理。
    ///
    /// 有未释放租约时先清空登记及缓存，待所有异步文件任务结束后再删除目录。
    func removeAll() {
        guard !removedAllFiles else { return }
        removedAllFiles = true
        imageLoader?.cancelAll()
        imageLoader?.clearCache()
        drafts.removeAll()
        committed.removeAll()
        if fileLeaseCount == 0 { try? fileManager.removeItem(at: directoryURL) }
    }
}
