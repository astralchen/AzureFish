import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 草稿读取结果，区分没有草稿、完整恢复和仅恢复有效附件的情况。
nonisolated struct ChatDraftLoadResult: Sendable {
    /// 文件引用已转换为目标页面副本的快照；没有磁盘清单时为 `nil`。
    var snapshot: ChatDraftSnapshot?
    /// 是否跳过了原件缺失、Live Photo 配对不完整或无法重建预览的附件。
    var hasMissingAttachments = false
}

/// 提交调用同步入队，磁盘工作异步执行；读、写、删除共享严格的提交顺序。
@MainActor
protocol ChatDraftStoring: AnyObject {
    /// 读取指定会话的草稿，并将可恢复资源复制到调用方拥有的目录。
    ///
    /// - Parameters:
    ///   - conversationID: 与保存时一致的稳定会话标识。
    ///   - directory: 页面附件目录，恢复后的文件由页面负责清理。
    /// - Returns: 读取任务；没有草稿时返回空结果，清单损坏、版本不支持或文件操作失败时以错误结束。
    func load(conversationID: String, into directory: URL) -> Task<ChatDraftLoadResult, Error>
    /// 保存完整快照及其独立资源副本，空快照等同于删除。
    ///
    /// - Parameter snapshot: 包含语义正文和已就绪附件的快照；调用方须在任务结束前保持源文件有效。
    /// - Returns: 保存任务；资源准备成功后才替换清单，失败时保留上一份完整版本并返回错误。
    func save(_ snapshot: ChatDraftSnapshot) -> Task<Void, Error>
    /// 删除指定会话的清单及其资源，不影响其他会话。
    ///
    /// - Parameter conversationID: 要清除的会话标识。
    /// - Returns: 删除任务；草稿不存在时成功完成，文件系统拒绝删除时返回错误。
    func remove(conversationID: String) -> Task<Void, Error>
}

/// 将会话草稿持久化到 Application Support 的存储实现。
///
/// 同一实例在主 Actor 上按调用顺序建立任务依赖，实际文件工作在后台执行。
/// 对同一存储目录的并发访问应复用一个实例，避免不同实例各自的任务链发生交错。
@MainActor
final class ChatDraftStore: ChatDraftStoring {
    /// Demo 页面共享的正式存储，使离开后的保存与下次进入的读取保持顺序。
    static let shared = ChatDraftStore()
    /// 各会话目录的根目录；正式环境为 `Application Support/ChatDrafts`。
    let directory: URL
    /// 最近一次排队操作的完成屏障；忽略其错误以允许后续任务继续执行。
    private var tail: Task<Void, Never>?

    /// 创建草稿存储，目录在实际文件操作时按需建立。
    ///
    /// - Parameter directory: 存储根目录；`nil` 使用应用的 Application Support，测试可指定独立临时目录。
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatDrafts", isDirectory: true)
    }

    /// 在调用瞬间建立任务顺序，将同步文件操作安排到后台任务执行。
    ///
    /// - Parameter operation: 不访问主 Actor 状态的文件操作；会等待前一操作结束后再执行。
    /// - Returns: 传递本次操作结果或错误的任务；前一任务失败不会阻断本次操作。
    private func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) -> Task<Value, Error> {
        let previous = tail
        let task = Task.detached(priority: .utility) {
            await previous?.value
            return try operation()
        }
        tail = Task { _ = await task.result }
        return task
    }

    /// 按提交顺序读取会话清单，并为目标页面创建独立附件副本。
    ///
    /// - Parameters:
    ///   - conversationID: 草稿所属会话的稳定标识。
    ///   - directory: 接收恢复资源的页面目录。
    /// - Returns: 包含恢复结果或读取错误的异步任务。
    func load(conversationID: String, into directory: URL) -> Task<ChatDraftLoadResult, Error> {
        let worker = ChatDraftFiles(root: self.directory, conversationID: conversationID)
        return enqueue { try worker.load(into: directory) }
    }

    /// 按提交顺序保存快照，文件准备及原子清单替换均在后台执行。
    ///
    /// - Parameter snapshot: 要提交的完整草稿；任务完成前不得删除其源文件。
    /// - Returns: 保存或删除空草稿的异步任务，通过任务结果报告失败。
    func save(_ snapshot: ChatDraftSnapshot) -> Task<Void, Error> {
        let worker = ChatDraftFiles(root: directory, conversationID: snapshot.conversationID)
        return enqueue { try worker.save(snapshot) }
    }

    /// 在此前所有存储操作结束后清除会话草稿。
    ///
    /// - Parameter conversationID: 要清除的会话标识。
    /// - Returns: 删除任务；不会取消此前已排队的保存，而是在其结束后删除结果。
    func remove(conversationID: String) -> Task<Void, Error> {
        let worker = ChatDraftFiles(root: directory, conversationID: conversationID)
        return enqueue { try worker.remove() }
    }
}

/// 在存储实例的有序后台任务中执行同步文件工作，避免主线程上的媒体复制及 JSON 编解码。
private nonisolated struct ChatDraftFiles: Sendable {
    /// 所有会话共用的草稿存储根目录。
    let root: URL
    /// 此次操作所属的会话标识，同时用于验证清单内容。
    let conversationID: String
    /// 使用会话标识摘要命名的独立目录，避免原始标识中的路径字符影响文件位置。
    private var directory: URL { root.appendingPathComponent(Self.key(conversationID), isDirectory: true) }
    /// 当前会话已提交版本的 JSON 清单位置。
    private var manifest: URL { directory.appendingPathComponent("draft.json") }
    /// 执行当前后台文件操作的系统文件管理器。
    private var fm: FileManager { .default }

    /// 将字符串转换为稳定的 SHA-256 十六进制文件名组成部分。
    ///
    /// - Parameter value: 会话标识或源文件 URL 字符串。
    /// - Returns: 不含路径分隔符的摘要字符串。
    private static func key(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 删除当前会话的整个草稿目录，不存在时不执行操作。
    ///
    /// - Throws: 文件系统删除目录时抛出的错误。
    func remove() throws {
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
    }

    /// 先准备资源，再原子替换清单，提交成功后回收不再引用的旧资源。
    ///
    /// 源 URL 相同的已就绪附件被视为内容不变，因此仅编辑文字时可复用既有副本。
    /// - Parameter snapshot: 源文件仍有效的页面快照；空快照直接删除会话草稿。
    /// - Throws: 目录创建、文件复制、编码或清单写入错误；失败时回收此次新建文件。
    func save(_ snapshot: ChatDraftSnapshot) throws {
        if snapshot.isEmpty { try remove(); return }
        let assets = directory.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        var created: [URL] = []
        do {
            var stored = try snapshot.mappingFiles { source in
                let name = Self.key(source.absoluteString) + "." + (source.pathExtension.isEmpty ? "data" : source.pathExtension)
                let target = assets.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path) {
                    // 先登记再复制，使复制中途失败留下的目标文件也能参与回滚。
                    created.append(target)
                    try fm.copyItem(at: source, to: target)
                }
                return URL(string: "assets/" + name)!
            }
            let old = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(ChatDraftSnapshot.self, from: $0) }
            stored.revision = (old?.revision ?? 0) &+ 1
            // 清单是提交边界；此前不删除旧文件，此后才允许回收失去引用的资源。
            try JSONEncoder().encode(stored).write(to: manifest, options: .atomic)
            let referenced = Set(stored.localFileURLs.map(\.lastPathComponent))
            for file in (try? fm.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)) ?? []
                where !referenced.contains(file.lastPathComponent) { try? fm.removeItem(at: file) }
        } catch {
            created.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    /// 验证清单资源路径只包含 `assets/文件名`，再解析为会话内的完整 URL。
    ///
    /// - Parameter relative: 清单中的相对 URL，不允许协议、基准 URL 或父目录跳转。
    /// - Returns: 当前会话资源目录中的文件 URL。
    /// - Throws: 路径结构不合法时抛出清单损坏错误。
    private func resolve(_ relative: URL) throws -> URL {
        guard relative.scheme == nil, relative.baseURL == nil,
              relative.pathComponents.count == 2, relative.pathComponents.first == "assets",
              !relative.pathComponents.contains("..") else { throw CocoaError(.fileReadCorruptFile) }
        return directory.appendingPathComponent(relative.relativeString)
    }

    /// 校验清单及资源，将可恢复内容复制为新页面拥有的附件。
    ///
    /// 原件缺失的项目单独跳过；缩略图按现有能力重建，Live Photo 必须保留完整配对。
    /// - Parameter destination: 新页面的附件目录；不存在时创建，不删除其中已有资源。
    /// - Returns: 使用页面文件 URL 的快照及部分恢复标记；无清单时返回空结果。
    /// - Throws: 清单解码、版本、会话、路径、身份校验或文件复制错误；回收已记录的恢复副本。
    func load(into destination: URL) throws -> ChatDraftLoadResult {
        guard fm.fileExists(atPath: manifest.path) else { return .init() }
        var snapshot = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: manifest))
        guard snapshot.version == 1, snapshot.conversationID == conversationID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // 先校验所有路径，再处理缺失项；不允许归档中的路径逃出会话目录。
        snapshot = try snapshot.mappingFiles(resolve)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var missing = false
        var copied: [URL] = []
        var imported: [URL: URL] = [:]
        /// 判断资源是否为现存普通文件，目录或不可读取的资源属性均视为无效。
        func exists(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        /// 将源资源复制到页面目录；重复引用复用本次恢复已创建的副本。
        ///
        /// - Parameter source: 经清单路径校验的本地资源 URL。
        /// - Returns: 页面拥有的资源 URL。
        /// - Throws: 复制资源时的文件系统错误。
        func copy(_ source: URL) throws -> URL {
            if let value = imported[source] { return value }
            let target = destination.appendingPathComponent("draft-\(UUID().uuidString)").appendingPathExtension(source.pathExtension)
            try fm.copyItem(at: source, to: target)
            copied.append(target)
            imported[source] = target
            return target
        }
        /// 按原顺序恢复有效媒体条目，并尝试补齐可重新生成的缩略图。
        ///
        /// - Parameter group: 文件路径已解析到磁盘草稿目录的媒体组。
        /// - Returns: 保留原组身份的有效条目子集；全部不可恢复时返回 `nil`。
        /// - Throws: 有效条目的文件复制错误；资源缺失或缩略图生成失败只跳过该条目。
        func restoreMedia(_ group: MediaGroupAttachment) throws -> MediaGroupAttachment? {
            var items: [MediaItem] = []
            for item in group.items {
                guard exists(item.originalFileURL), item.livePhotoVideoURL.map(exists) ?? true else {
                    missing = true; continue
                }
                if !exists(item.thumbnailFileURL) {
                    // 缩略图可重建，但 Live Photo 配对视频必须完整。
                    let target = destination.appendingPathComponent("draft-thumbnail-\(UUID().uuidString).jpg")
                    do {
                        try Self.makeThumbnail(item, at: target)
                        copied.append(target)
                        imported[item.thumbnailFileURL] = target
                    } catch { missing = true; continue }
                }
                items.append(try item.mappingDraftFiles(copy))
            }
            return items.isEmpty ? nil : .init(id: group.id, items: items)
        }
        /// 按附件类型恢复必需资源，允许文件或链接缺少可后续补齐的预览图。
        ///
        /// - Parameter attachment: 文件路径已校验的内联附件或独立语音附件。
        /// - Returns: 引用页面副本的附件；必需资源不可恢复时返回 `nil` 并记录部分恢复状态。
        /// - Throws: 有效资源复制时的文件系统错误。
        func restoreAttachment(_ attachment: Attachment) throws -> Attachment? {
            switch attachment {
            case .audio(let audio):
                guard exists(audio.fileURL) else { missing = true; return nil }
                return .audio(try audio.mappingDraftFiles(copy))
            case .mediaGroup(let group): return try restoreMedia(group).map(Attachment.mediaGroup)
            case .file(var file):
                guard exists(file.fileURL) else { missing = true; return nil }
                if let url = file.thumbnailURL, !exists(url) { file.thumbnailURL = nil }
                return try Attachment.file(file).mappingDraftFiles(copy)
            case .link(var link):
                if let url = link.imageURL, !exists(url) { link.imageURL = nil }
                if let url = link.iconURL, !exists(url) { link.iconURL = nil }
                return try Attachment.link(link).mappingDraftFiles(copy)
            }
        }
        do {
            snapshot.documents = try snapshot.documents.compactMap(restoreAttachment)
            let ids = Set(snapshot.documents.map(\.id))
            guard ids.count == snapshot.documents.count else { throw CocoaError(.fileReadCorruptFile) }
            // 正文只保留可恢复且首次出现的附件引用，防止缺失或重复身份安装到编辑器。
            var used: Set<UUID> = []
            snapshot.segments = snapshot.segments.filter {
                if case .attachment(let id) = $0 { return ids.contains(id) && used.insert(id).inserted }
                return true
            }
            snapshot.documents = snapshot.documents.filter { used.contains($0.id) }
            snapshot.media = try snapshot.media.flatMap(restoreMedia)
            snapshot.audio = try snapshot.audio.flatMap { try restoreAttachment(.audio($0))?.audio }
            return .init(snapshot: snapshot, hasMissingAttachments: missing)
        } catch {
            copied.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    /// 从图片原件或视频首帧生成最长边不超过 480 像素的 JPEG 缩略图。
    ///
    /// 在后台文件任务中执行；应用媒体方向信息，不改变快照中的原始像素尺寸。
    /// - Parameters:
    ///   - item: 原件有效、需要补齐缩略图的媒体条目。
    ///   - url: 新页面目录中用于写入 JPEG 的目标文件 URL。
    /// - Throws: 原件无法解码、视频取帧失败或缩略图无法写入时的错误。
    private static func makeThumbnail(_ item: MediaItem, at url: URL) throws {
        let image: CGImage
        if item.kind.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.originalFileURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            image = try generator.copyCGImage(at: .zero, actualTime: nil)
        } else {
            guard let source = CGImageSourceCreateWithURL(item.originalFileURL as CFURL, nil),
                  let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480
                  ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
            image = value
        }
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
}
