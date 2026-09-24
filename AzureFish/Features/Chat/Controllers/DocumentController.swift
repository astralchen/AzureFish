import Foundation
import LinkPresentation
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// 内联文档卡片的附件值与异步导入状态。
nonisolated struct DocumentDraft: Equatable, Sendable {
    /// 文档草稿从占位到可发送或失败的处理状态。
    enum Status: Equatable, Sendable {
        /// 依次表示正在导入、内容已就绪以及导入失败。
        case importing, ready, failed
    }
    /// 草稿当前携带的文件、链接或媒体附件值。
    var attachment: Attachment
    /// 当前处理状态；直接创建的有效附件默认为已就绪。
    var status: Status = .ready
    /// 底层附件的稳定标识符，用于关联占位、异步更新和删除。
    var id: UUID { attachment.id }
}

/// 文件和网页的独立草稿所有者。删除、提交或退出后，迟到的导入结果只做清理。
@available(iOS 17.0, *)
final class DocumentController: NSObject, UIDocumentPickerDelegate {
    /// 与页面其他附件控制器共享的本地文件存储。
    let store: any AttachmentStoring
    /// 粘贴媒体与照片选择器共用图片处理预算。
    let imageLoader: MediaImageLoader
    /// 按稳定标识符登记的当前文档草稿集合。
    private(set) var drafts: [UUID: DocumentDraft] = [:]
    /// 单个草稿插入并完成存储登记时调用的闭包。
    var draftInserted: ((DocumentDraft) -> Void)?
    /// 混合粘贴完成占位登记后调用的闭包，内容保持原始顺序。
    var contentsInserted: (([EditorInsertion]) -> Void)?
    /// 用户取消系统文件选择器时调用的闭包。
    var pickerCancelled: (() -> Void)?
    /// 已有身份的草稿内容或导入状态更新时调用的闭包。
    var draftUpdated: ((DocumentDraft) -> Void)?
    /// 开始插入链接或混合粘贴内容前调用的闭包。
    var willInsert: (() -> Void)?
    /// 按附件身份管理的复制、元数据或缩略图任务。
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// 按链接身份保存的系统网页元数据提供者。
    private var providers: [UUID: LPMetadataProvider] = [:]
    /// 按附件身份保存的系统项目加载进度，支持取消导入。
    private var imports: [UUID: Progress] = [:]
    /// 草稿删除前通知页面关闭仍在使用该文件的预览。
    var willRemoveDraft: ((UUID) -> Void)?

    /// 创建使用指定页面附件存储的文档控制器。
    init(store: any AttachmentStoring, imageLoader: MediaImageLoader? = nil) {
        self.store = store
        self.imageLoader = imageLoader ?? MediaImageLoader()
    }

    /// 保留录音文件与稳定身份，将其转换为可内联编辑的文件草稿并请求缩略图。
    func adoptRecording(_ audio: AudioAttachment) {
        let file = FileAttachment(
            id: audio.id, fileURL: audio.fileURL,
            displayName: "Audio Message.\(audio.fileURL.pathExtension)",
            typeIdentifier: UTType(filenameExtension: audio.fileURL.pathExtension)?.identifier ?? UTType.audio.identifier,
            byteCount: Int64((try? audio.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        )
        insert(.init(attachment: .file(file)))
        fetchThumbnail(file)
    }

    /// 展示允许多选、以复制方式导入任意文件类型的系统选择器。
    func presentPicker(from controller: UIViewController) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        controller.present(picker, animated: true)
    }

    /// 按系统返回顺序将已选择文件交给混合内容导入流程。
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        insertPasted(urls.map { .fileURL($0) })
    }

    /// 将系统文件选择取消事件转发给页面。
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pickerCancelled?()
    }

    /// 先同步插入有序占位，再异步复制文件；即使导入失败也保留可删除的卡片。
    func importDocument(_ source: URL) {
        let destination = store.makeFileURL(prefix: "document", pathExtension: source.pathExtension)
        let file = FileAttachment(
            id: UUID(), fileURL: destination, displayName: source.lastPathComponent,
            typeIdentifier: UTType(filenameExtension: source.pathExtension)?.identifier ?? UTType.data.identifier,
            byteCount: 0
        )
        insert(.init(attachment: .file(file), status: .importing))
        tasks[file.id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Int64? in
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                do {
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
                    try FileManager.default.copyItem(at: source, to: destination)
                    return Int64(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                } catch { return nil }
            }.value
            guard let self, !Task.isCancelled, drafts[file.id] != nil else {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            tasks[file.id] = nil
            guard let size = result else {
                store.removeFile(at: destination)
                update(.init(attachment: .file(file), status: .failed))
                return
            }
            let imported = FileAttachment(
                id: file.id, fileURL: destination, displayName: file.displayName,
                typeIdentifier: file.typeIdentifier, byteCount: size
            )
            update(.init(attachment: .file(imported)))
            fetchThumbnail(imported)
        }
    }

    /// 校验网页 URL，插入可立即发送的链接草稿并异步补充元数据。
    ///
    /// - Returns: URL 符合 HTTP 或 HTTPS 规则并已插入时为 `true`。
    @discardableResult
    func insertLink(_ url: URL) -> Bool {
        guard LinkAttachment.accepts(url) else { return false }
        willInsert?()
        let link = LinkAttachment(url: url)
        insert(.init(attachment: .link(link)))
        fetchLink(link)
        return true
    }

    /// 请求网页标题、封面和站点图标，并仅更新仍活跃的链接草稿。
    ///
    /// 元数据失败不改变原 URL 的可发送性；未交给存储的临时图片在退出时清理。
    private func fetchLink(_ link: LinkAttachment) {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        providers[link.id] = provider
        tasks[link.id] = Task { [weak self] in
            guard let metadata = try? await provider.startFetchingMetadata(for: link.url),
                  let self, !Task.isCancelled, drafts[link.id] != nil else { return }
            var updated = link
            updated.title = metadata.title
            var pendingFiles: [URL] = []
            defer { pendingFiles.forEach { self.store.removeFile(at: $0) } }
            // 封面和站点图标是两种展示语义，不能把 favicon 当成大图。
            for (isIcon, itemProvider) in [(false, metadata.imageProvider), (true, metadata.iconProvider)] {
                guard let itemProvider,
                      let data = try? await Self.imageData(from: itemProvider),
                      let image = UIImage(data: data), let png = image.pngData(),
                      !Task.isCancelled, drafts[link.id] != nil else { continue }
                let path = store.makeFileURL(prefix: isIcon ? "link-icon" : "link-image", pathExtension: "png")
                if (try? png.write(to: path)) != nil {
                    pendingFiles.append(path)
                    if isIcon { updated.iconURL = path } else { updated.imageURL = path }
                }
            }
            guard !Task.isCancelled, drafts[link.id] != nil else { return }
            update(.init(attachment: .link(updated)))
            pendingFiles.removeAll()
            tasks[link.id] = nil
            providers[link.id] = nil
        }
    }

    /// 先注册整批占位，按剪贴板顺序替换选区；异步结果只更新同一身份。
    func insertPasted(_ sources: [PasteSource]) {
        guard !sources.isEmpty else { return }
        willInsert?()
        var batch: [DocumentDraft] = []
        var contents: [EditorInsertion] = []
        var work: [(PasteSource, FileAttachment)] = []
        for source in sources {
            if case .text(let text) = source { contents.append(.text(text)); continue }
            if case .link(let url) = source {
                guard LinkAttachment.accepts(url) else { continue }
                let draft = DocumentDraft(attachment: .link(.init(url: url)))
                batch.append(draft)
                contents.append(.attachment(draft))
                continue
            }
            let type: UTType
            let name: String
            switch source {
            case .provider(let provider, let identifier):
                type = UTType(identifier) ?? .data
                name = provider.suggestedName ?? Localization.text("imessage.attachment.pastedFile")
            case .fileURL(let url):
                type = UTType(filenameExtension: url.pathExtension) ?? .data
                name = url.lastPathComponent
            case .link, .text: continue
            }
            let ext = type.preferredFilenameExtension ?? (type.conforms(to: .image) ? "png" : (name as NSString).pathExtension)
            let filename = (name as NSString).pathExtension.isEmpty && !ext.isEmpty ? "\(name).\(ext)" : name
            let file = FileAttachment(
                id: UUID(), fileURL: store.makeFileURL(prefix: "paste", pathExtension: ext),
                displayName: filename, typeIdentifier: type.identifier, byteCount: 0
            )
            let draft = DocumentDraft(attachment: .file(file), status: .importing)
            batch.append(draft)
            contents.append(.attachment(draft))
            work.append((source, file))
        }
        for draft in batch {
            drafts[draft.id] = draft
            store.registerDraft(draft.attachment)
        }
        contentsInserted?(contents)
        for draft in batch {
            if case .link(let link) = draft.attachment { fetchLink(link) }
        }
        for (source, file) in work { importPasted(source, file: file) }
    }

    /// 复制粘贴来源并更新原占位，按内容类型生成媒体元数据或文件缩略图。
    ///
    /// 草稿删除或任务取消后只清理文件，不恢复已失效的卡片。
    private func importPasted(_ source: PasteSource, file: FileAttachment) {
        tasks[file.id] = Task { [weak self] in
            guard let self, !Task.isCancelled, drafts[file.id] != nil else { return }
            let copied = await copyPaste(source, file: file)
            imports[file.id] = nil
            guard !Task.isCancelled, drafts[file.id] != nil else {
                if let copied { store.removeFile(at: copied.fileURL) }
                return
            }
            guard let copied else {
                store.removeFile(at: file.fileURL)
                update(.init(attachment: .file(file), status: .failed))
                tasks[file.id] = nil
                return
            }
            let type = UTType(copied.typeIdentifier) ?? .data
            if type.conforms(to: .image) || type.conforms(to: .movie) {
                let thumbnail = store.makeFileURL(prefix: "paste-thumbnail", pathExtension: "jpg")
                do {
                    let metadata = try await imageLoader.scheduler.run(kind: .importing) {
                        try await MediaImportProcessor.makeMetadata(
                            originalURL: copied.fileURL, thumbnailURL: thumbnail,
                            isVideo: type.conforms(to: .movie)
                        )
                    }
                    guard !Task.isCancelled, drafts[file.id] != nil else {
                        store.removeFile(at: copied.fileURL); store.removeFile(at: thumbnail); return
                    }
                    let media = MediaItem(
                        id: file.id, assetIdentifier: nil, originalFileURL: copied.fileURL,
                        thumbnailFileURL: thumbnail, pixelSize: metadata.pixelSize,
                        kind: metadata.kind, isAnimatedImage: metadata.isAnimatedImage
                    )
                    update(.init(attachment: .mediaGroup(.init(id: file.id, items: [media]))))
                } catch {
                    store.removeFile(at: copied.fileURL)
                    store.removeFile(at: thumbnail)
                    if !Task.isCancelled, drafts[file.id] != nil {
                        update(.init(attachment: .file(file), status: .failed))
                    }
                }
                tasks[file.id] = nil
            } else {
                update(.init(attachment: .file(copied)))
                fetchThumbnail(copied)
            }
        }
    }

    /// 将文件 URL 或项目提供者内容复制到草稿目标位置。
    ///
    /// 文件表示不可用时尝试图像对象或数据表示；失败返回 `nil`，不发布界面状态。
    private func copyPaste(_ source: PasteSource, file: FileAttachment) async -> FileAttachment? {
        let destination = file.fileURL
        var imported = file
        switch source {
        case .fileURL(let url):
            let success = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return false }
                    try FileManager.default.copyItem(at: url, to: destination)
                    return true
                } catch { return false }
            }.value
            guard success else { return nil }
        case .provider(let provider, let identifier):
            let success = await withCheckedContinuation { continuation in
                imports[file.id] = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    // NSItemProvider 在回调返回后删除临时文件，必须在这里同步复制。
                    do {
                        guard let url else { continuation.resume(returning: false); return }
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: true)
                    } catch { continuation.resume(returning: false) }
                }
            }
            if !success {
                guard !Task.isCancelled, drafts[file.id] != nil else { return nil }
                if UTType(identifier)?.conforms(to: .image) == true, provider.canLoadObject(ofClass: UIImage.self) {
                    let png: Data? = await withCheckedContinuation { continuation in
                        imports[file.id] = provider.loadObject(ofClass: UIImage.self) { image, _ in
                            continuation.resume(returning: (image as? UIImage)?.pngData())
                        }
                    }
                    guard let png, !Task.isCancelled, drafts[file.id] != nil else { return nil }
                    let pngURL = destination.deletingPathExtension().appendingPathExtension("png")
                    do { try png.write(to: pngURL) } catch { return nil }
                    imported = .init(id: file.id, fileURL: pngURL,
                        displayName: (file.displayName as NSString).deletingPathExtension + ".png",
                        typeIdentifier: UTType.png.identifier, byteCount: Int64(png.count))
                } else {
                    let data: Data? = await withCheckedContinuation { continuation in
                        imports[file.id] = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                            continuation.resume(returning: data)
                        }
                    }
                    guard let data, !Task.isCancelled, drafts[file.id] != nil else { return nil }
                    do { try data.write(to: destination) } catch { return nil }
                }
            }
        case .link, .text: return nil
        }
        return .init(id: imported.id, fileURL: imported.fileURL, displayName: imported.displayName,
                     typeIdentifier: imported.typeIdentifier,
                     byteCount: Int64((try? imported.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }

    /// 异步读取项目提供者的图像数据；没有数据时抛出系统错误或文件读取错误。
    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    /// 登记新草稿及其文件归属，并通知编辑器插入卡片。
    private func insert(_ draft: DocumentDraft) {
        drafts[draft.id] = draft
        store.registerDraft(draft.attachment)
        draftInserted?(draft)
    }

    /// 更新仍存在的草稿、同步文件归属并通知编辑器刷新同一身份。
    private func update(_ draft: DocumentDraft) {
        guard drafts[draft.id] != nil else { return }
        drafts[draft.id] = draft
        store.registerDraft(draft.attachment)
        draftUpdated?(draft)
    }

    /// 使用 Quick Look 生成文件缩略图，并仅向仍活跃的草稿回填本地图片 URL。
    private func fetchThumbnail(_ file: FileAttachment) {
        tasks[file.id] = Task { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: file.fileURL, size: CGSize(width: 100, height: 120), scale: 2,
                representationTypes: .all
            )
            guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                  let self, !Task.isCancelled, drafts[file.id] != nil,
                  let data = representation.uiImage.pngData() else { return }
            let url = store.makeFileURL(prefix: "file-thumbnail", pathExtension: "png")
            guard (try? data.write(to: url)) != nil else { return }
            var updated = file
            updated.thumbnailURL = url
            update(.init(attachment: .file(updated)))
            tasks[file.id] = nil
        }
    }

    /// 只登记恢复后的本地资源；编辑器由页面按原片段顺序批量安装。
    ///
    /// 缺失的文件缩略图或链接预览通过现有异步能力补齐，不重新导入原件。
    /// - Parameter attachments: 已复制到页面存储目录的有效附件，按原身份登记为就绪状态。
    func restoreDrafts(_ attachments: [Attachment]) {
        for attachment in attachments {
            drafts[attachment.id] = .init(attachment: attachment)
            store.registerDraft(attachment)
            switch attachment {
            case .file(let file) where file.thumbnailURL == nil: fetchThumbnail(file)
            case .link(let link) where link.imageURL == nil: fetchLink(link)
            default: break
            }
        }
    }

    /// 按指定顺序返回可发送附件。
    ///
    /// - Parameter ids: 必须恰好覆盖当前草稿集合且没有重复项的身份序列。
    /// - Returns: 全部草稿已就绪时返回附件数组；否则返回 `nil`。
    func attachments(for ids: [UUID]) -> [Attachment]? {
        guard Set(ids) == Set(drafts.keys), Set(ids).count == ids.count else { return nil }
        let values = ids.compactMap { drafts[$0] }
        guard values.allSatisfy({ $0.status == .ready }) else { return nil }
        return values.map(\.attachment)
    }

    /// 取消指定草稿的异步工作，关闭其预览并删除未提交文件。
    func remove(_ id: UUID) {
        cancelWork(id)
        willRemoveDraft?(id)
        drafts[id] = nil
        store.discardDraft(id: id)
    }

    /// 取消指定草稿的补充处理，并将附件归属转为已提交消息资源。
    func commit(_ ids: [UUID]) {
        for id in ids {
            cancelWork(id)
            if let draft = drafts.removeValue(forKey: id), !store.commitDraft(id: id) {
                store.registerCommitted(draft.attachment)
            }
        }
    }

    /// 逐项移除全部文档草稿及其拥有的未提交资源。
    func discardAll() {
        for id in Array(drafts.keys) { remove(id) }
    }

    /// 取消指定附件的项目加载、异步任务与网页元数据请求。
    private func cancelWork(_ id: UUID) {
        imports.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
        providers.removeValue(forKey: id)?.cancel()
    }

}
