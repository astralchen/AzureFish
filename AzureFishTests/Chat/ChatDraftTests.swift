import Foundation
import Testing
import UIKit
@testable import AzureFish

/// 覆盖草稿存储、资源所有权、内容恢复及提交竞态的回归测试。
///
/// 每个用例使用独立临时目录，不读写正式用户草稿；控制器相关断言在支持的系统上执行。
@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatDraftTests {
    /// 验证全部附件类型及多语言富文本往返一致，清单只记录相对路径且不依赖原页面文件。
    @Test func allAttachmentKindsAndRichTextRoundTripWithoutAbsolutePaths() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = try fixture.snapshot()
        try await fixture.store.save(original).value
        let manifest = try fixture.manifest()
        let json = try String(contentsOf: manifest, encoding: .utf8)
        #expect(!json.contains(fixture.root.lastPathComponent))
        let encoded = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: manifest))
        #expect(encoded.localFileURLs.allSatisfy { $0.scheme == nil && $0.relativeString.hasPrefix("assets/") })
        let first = try #require(try await fixture.store.load(conversationID: "chat", into: fixture.output()).value.snapshot)
        #expect(first.segments == original.segments)
        #expect(first.documents.map(\.id) == original.documents.map(\.id))
        #expect(first.media?.items.map(\.id) == original.media?.items.map(\.id))
        #expect(first.media?.items.map(\.isAnimatedImage) == [false, true, false, false])
        #expect(first.media?.items.map(\.isLivePhoto) == [false, false, true, false])
        #expect(first.audio?.waveform == original.audio?.waveform)
        #expect(first.audio?.duration == original.audio?.duration)
        for (source, restored) in zip(original.localFileURLs, first.localFileURLs) {
            #expect(try Data(contentsOf: source) == Data(contentsOf: restored))
            #expect(source != restored)
        }
        // 删除整个原页面目录，再用新实例模拟进程重启。
        try FileManager.default.removeItem(at: fixture.sources)
        let restarted = ChatDraftStore(directory: fixture.disk)
        let next = try await restarted.load(conversationID: "chat", into: fixture.output()).value
        #expect(next.snapshot?.segments == original.segments)
        #expect(!next.hasMissingAttachments)
    }

    /// 验证纯文本变更复用媒体副本、递增清单修订号，并且单会话删除不影响其他会话。
    @Test func textEditsReuseAssetsAndConversationsRemainIsolated() async throws {
        let f = try Fixture()
        defer { f.clean() }
        var snapshot = try f.snapshot()
        try await f.store.save(snapshot).value
        let assets = try f.manifest().deletingLastPathComponent().appendingPathComponent("assets")
        let before = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.contentModificationDateKey])
        let dates = try before.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        snapshot.segments.append(.text(" changed"))
        try await f.store.save(snapshot).value
        #expect(try before.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } == dates)
        let stored = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: f.manifest()))
        #expect(stored.revision == 2)
        try await f.store.save(.init(conversationID: "other", segments: [.text("other")])).value
        try await f.store.remove(conversationID: "chat").value
        #expect(try await f.store.load(conversationID: "chat", into: f.output()).value.snapshot == nil)
        #expect(try await f.store.load(conversationID: "other", into: f.output()).value.snapshot?.segments == [.text("other")])
    }

    /// 验证新快照的源文件复制失败时，上一份完整清单仍可读取。
    @Test func failedCopyKeepsLastCompleteVersion() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let old = ChatDraftSnapshot(conversationID: "chat", segments: [.text("saved")])
        try await f.store.save(old).value
        var next = try f.snapshot()
        let missing = AudioAttachment(fileURL: f.sources.appendingPathComponent("missing.m4a"), duration: 1, waveform: [0.5])
        next.audio = missing
        do { try await f.store.save(next).value; Issue.record("Missing source must fail save") } catch {}
        let result = try await f.store.load(conversationID: "chat", into: f.output()).value
        #expect(result.snapshot?.segments == old.segments)
        #expect(result.snapshot?.documents.isEmpty == true)
    }

    /// 验证原件或 Live Photo 配对视频缺失时只跳过受影响条目，保留其他媒体顺序和正文。
    @Test func missingOriginalAndLivePairDropOnlyAffectedItems() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.store.save(f.snapshot()).value
        let manifest = try f.manifest()
        let stored = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: manifest))
        let group = try #require(stored.media)
        for relative in [group.items[0].originalFileURL, try #require(group.items[2].livePhotoVideoURL)] {
            try FileManager.default.removeItem(at: manifest.deletingLastPathComponent().appendingPathComponent(relative.relativeString))
        }
        let result = try await f.store.load(conversationID: "chat", into: f.output()).value
        #expect(result.hasMissingAttachments)
        #expect(result.snapshot?.media?.items.map(\.id) == [group.items[1].id, group.items[3].id])
        #expect(result.snapshot?.segments == stored.segments)
    }

    /// 使用可解码的图片验证缩略图缺失时能从原件重建，且不误报附件丢失。
    @Test func missingImageThumbnailIsRegenerated() async throws {
        let f = try Fixture()
        defer { f.clean() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let source = try f.file("image.jpg", data: #require(image.jpegData(compressionQuality: 0.8)))
        let thumb = try f.file("thumb.jpg", data: #require(image.jpegData(compressionQuality: 0.8)))
        let media = MediaGroupAttachment(items: [.init(assetIdentifier: nil, originalFileURL: source,
            thumbnailFileURL: thumb, pixelSize: CGSize(width: 40, height: 20), kind: .image)])
        try await f.store.save(.init(conversationID: "chat", media: media)).value
        let manifest = try f.manifest()
        let stored = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: manifest))
        let relative = try #require(stored.media?.items.first?.thumbnailFileURL)
        try FileManager.default.removeItem(at: manifest.deletingLastPathComponent().appendingPathComponent(relative.relativeString))
        let result = try await f.store.load(conversationID: "chat", into: f.output()).value
        let restored = try #require(result.snapshot?.media?.items.first)
        #expect(UIImage(contentsOfFile: restored.thumbnailFileURL.path) != nil)
        #expect(!result.hasMissingAttachments)
    }

    /// 验证未知版本、越界资源路径及损坏 JSON 均以读取错误结束。
    @Test func corruptVersionAndEscapingPathFailSafely() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try await f.store.save(f.snapshot()).value
        let path = try f.manifest()
        var snapshot = try JSONDecoder().decode(ChatDraftSnapshot.self, from: Data(contentsOf: path))
        snapshot.version = 99
        try JSONEncoder().encode(snapshot).write(to: path)
        do { _ = try await f.store.load(conversationID: "chat", into: f.output()).value; Issue.record("Unknown version accepted") } catch {}
        snapshot.version = 1
        snapshot.audio = .init(fileURL: URL(string: "../outside.m4a")!, duration: 1, waveform: [])
        try JSONEncoder().encode(snapshot).write(to: path)
        do { _ = try await f.store.load(conversationID: "chat", into: f.output()).value; Issue.record("Escaping path accepted") } catch {}
        try Data("broken".utf8).write(to: path)
        do { _ = try await f.store.load(conversationID: "chat", into: f.output()).value; Issue.record("Corrupt JSON accepted") } catch {}
    }

    /// 验证文件租约延迟页面清理直至复制结束，且旧防抖任务不会覆盖后续清空操作。
    @Test func pendingWritesCannotResurrectClearedDraftAndFileLeaseDefersCleanup() async throws {
        guard #available(iOS 26.0, *) else { return }
        let f = try Fixture()
        defer { f.clean() }
        let page = PageAttachmentStore(parentDirectory: f.root)
        let file = try page.importFile(at: f.file("document.pdf"), prefix: "doc", pathExtension: nil)
        let attachment = Attachment.file(.init(id: UUID(), fileURL: file, displayName: "doc.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 3))
        page.registerDraft(attachment)
        let coordinator = ChatDraftCoordinator(conversationID: "chat", store: f.store)
        coordinator.acquireFiles = { page.acquireFileLease() }
        coordinator.changed(.init(conversationID: "chat", segments: [.attachment(attachment.id)], documents: [attachment]), immediately: true)
        page.discardDraft(id: attachment.id)
        page.removeAll()
        #expect(FileManager.default.fileExists(atPath: file.path))
        await coordinator.flush()?.value
        #expect(!FileManager.default.fileExists(atPath: page.directoryURL.path))
        #expect(try await f.store.load(conversationID: "chat", into: f.output()).value.snapshot?.documents.count == 1)
        coordinator.changed(.init(conversationID: "chat", segments: [.text("old pending")]))
        coordinator.changed(.init(conversationID: "chat"), immediately: true)
        await coordinator.flush()?.value
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(try await f.store.load(conversationID: "chat", into: f.output()).value.snapshot == nil)
    }

    /// 验证页面恢复空白与四种文字格式、保持键盘关闭，且仅在消息模型接受发送后清除草稿。
    @Test func controllerRestoresWhitespaceAndFormattingThenClearsOnlyAcceptedSend() async throws {
        guard #available(iOS 26.0, *) else { return }
        let f = try Fixture()
        defer { f.clean() }
        let segments: [DraftSegment] = [.richText(.init(runs: [.init("  中文👨‍👩‍👧‍👦\nمرحبا", style: [.bold, .italic, .underline, .strikethrough])])), .text("\n  ")]
        try await f.store.save(.init(conversationID: "chat", segments: segments)).value
        let chat = f.controller()
        chat.loadViewIfNeeded()
        #expect(chat.isRestoringDraft)
        await chat.draftRestoreTask?.value
        let expected = MessageText(runs: [.init("  中文👨‍👩‍👧‍👦\nمرحبا", style: [.bold, .italic, .underline, .strikethrough]), .init("\n  ")])
        #expect(MessageText(attributedString: chat.composerView.textView.attributedText) == expected)
        #expect(!chat.composerView.textView.isFirstResponder)
        let accepted = chat.composerView.actionRequested
        chat.composerView.actionRequested = { _ in false }
        chat.composerView.sendButtonDidTap()
        #expect(!chat.makeDraftSnapshot().isEmpty)
        #expect(try await f.store.load(conversationID: "chat", into: f.output()).value.snapshot != nil)
        chat.composerView.actionRequested = accepted
        chat.composerView.sendButtonDidTap()
        await chat.draftCoordinator?.flush()?.value
        #expect(chat.makeDraftSnapshot().isEmpty)
        #expect(try await f.store.load(conversationID: "chat", into: f.output()).value.snapshot == nil)
        chat.viewModel.cancelPendingReply()
    }

    /// 验证混合正文与媒体按原身份和顺序安装到各控制器，恢复后的媒体删除可再次持久化。
    @Test func controllerSavesMixedSegmentsAndRestoresControllersWithSameOrder() async throws {
        guard #available(iOS 26.0, *) else { return }
        let f = try Fixture()
        defer { f.clean() }
        var original = try f.snapshot()
        original.audio = nil // 独立音频预览与混合编辑器互斥。
        try await f.store.save(original).value
        let chat = f.controller()
        chat.loadViewIfNeeded()
        await chat.draftRestoreTask?.value
        #expect(chat.composerView.persistentDraftSegments == original.segments)
        #expect(chat.photoController.draft?.items.map(\.id) == original.media?.items.map(\.id))
        #expect(chat.documentController.drafts.count == original.documents.count)
        let removed = try #require(original.media?.items[1].id)
        chat.photoController.removeItem(id: removed)
        chat.flushDraftBeforeLeaving()
        await chat.draftCoordinator?.operation?.value
        let restored = try await f.store.load(conversationID: "chat", into: f.output()).value
        #expect(restored.snapshot?.media?.items.contains { $0.id == removed } == false)
        #expect(restored.snapshot?.segments == original.segments)
        chat.documentController.discardAll()
    }

    /// 验证语音恢复为零进度的暂停预览，录音状态及尚未导入完成的附件不进入快照。
    @Test func audioPreviewRestoresPausedAndIncompleteDraftsAreExcluded() async throws {
        guard #available(iOS 26.0, *) else { return }
        let f = try Fixture()
        defer { f.clean() }
        let audio = try #require(f.snapshot().audio)
        try await f.store.save(.init(conversationID: "chat", audio: audio)).value
        let chat = f.controller()
        chat.loadViewIfNeeded()
        await chat.draftRestoreTask?.value
        guard case .audioPreview(let restored, let playing, let progress) = chat.audioController.state else {
            Issue.record("Expected preview"); return
        }
        #expect(restored.id == audio.id)
        #expect(!playing && progress == 0)
        chat.audioController.state = .recording(elapsed: 2, waveform: [0.5])
        let bad = DocumentDraft(attachment: .file(.init(id: UUID(), fileURL: f.sources.appendingPathComponent("missing"),
            displayName: "pending", typeIdentifier: "public.data", byteCount: 0)), status: .importing)
        chat.composerView.insertDocument(bad)
        #expect(chat.makeDraftSnapshot().isEmpty)
        chat.audioController.state = .idle
        await chat.draftCoordinator?.flush()?.value
    }

    /// 验证部分导入中的媒体组只保存就绪子集，紧接退出的读取排在最后一次写入之后。
    @Test func partiallyImportedMediaSavesOnlyReadyItemsAndImmediateReentryReadsLastWrite() async throws {
        guard #available(iOS 26.0, *) else { return }
        let f = try Fixture()
        defer { f.clean() }
        let chat = f.controller()
        chat.loadViewIfNeeded()
        await chat.draftRestoreTask?.value
        let media = try #require(f.snapshot().media)
        chat.photoController.restoreDraft(media)
        let importing = PhotoPickerController.DraftEntry(assetIdentifier: "still-importing")
        chat.photoController.entries.insert(importing, at: 1)
        chat.photoController.publishDraft()
        #expect(chat.photoController.draft?.canSend == false)
        #expect(chat.makeDraftSnapshot().media?.items.map(\.id) == media.items.map(\.id))
        chat.flushDraftBeforeLeaving()
        // 不等待上一页写入，立即创建下一页；读取必须排在写入之后。
        let next = f.controller()
        next.loadViewIfNeeded()
        await next.draftRestoreTask?.value
        #expect(next.photoController.draft?.items.map(\.id) == media.items.map(\.id))
        #expect(next.photoController.draft?.canSend == true)
        await chat.draftCoordinator?.operation?.value
    }

    /// 为单个用例提供独立的源文件、磁盘草稿目录及可注入控制器。
    @MainActor
    private final class Fixture {
        /// 当前用例独占的临时根目录，使用随机身份避免并行运行时相互覆盖。
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDraftTests-\(UUID().uuidString)")
        /// 模拟原页面拥有的附件源目录，可删除它来验证草稿副本独立性。
        var sources: URL { root.appendingPathComponent("page") }
        /// 模拟 Application Support 草稿存储的测试目录。
        var disk: URL { root.appendingPathComponent("disk") }
        /// 当前用例共享的存储实例，使各页面的读取与写入保持提交顺序。
        let store: ChatDraftStore

        /// 创建隔离存储及源文件目录。
        ///
        /// - Throws: 无法创建测试目录时的文件系统错误。
        init() throws {
            store = ChatDraftStore(directory: root.appendingPathComponent("disk"))
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        }
        /// 尽力删除当前用例的全部临时文件，供测试的 `defer` 清理使用。
        func clean() { try? FileManager.default.removeItem(at: root) }
        /// 返回尚未创建的独立恢复目标目录，每次调用均模拟一个新页面。
        func output() -> URL { root.appendingPathComponent(UUID().uuidString) }
        /// 在模拟页面目录中写入附件原件或预览资源。
        ///
        /// - Parameters:
        ///   - name: 测试文件名，应为源目录内的直接子项。
        ///   - data: 文件字节；默认占位数据只用于复制与元数据测试，不代表有效媒体编码。
        /// - Returns: 创建的源文件 URL。
        /// - Throws: 无法写入源文件时的错误。
        func file(_ name: String, data: Data = Data([1, 2, 3])) throws -> URL {
            let url = sources.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        /// 定位存储目录中第一个会话的清单，仅用于当前只保存一个会话的测试步骤。
        ///
        /// - Returns: 该会话的 `draft.json` URL。
        /// - Throws: 枚举目录失败或没有会话目录时的错误。
        func manifest() throws -> URL {
            let dirs = try FileManager.default.contentsOfDirectory(at: disk, includingPropertiesForKeys: nil)
            return try #require(dirs.first).appendingPathComponent("draft.json")
        }
        /// 创建涵盖富文本、文件、链接、各类媒体及独立语音的持久化测试快照。
        ///
        /// 使用占位文件验证复制和元数据往返，不用于真实解码或播放。
        /// - Returns: 会话标识为 `chat`、拥有固定片段顺序的新快照。
        /// - Throws: 任一附件源文件无法创建时的错误。
        func snapshot() throws -> ChatDraftSnapshot {
            let file = Attachment.file(.init(id: UUID(), fileURL: try file("document.pdf"), displayName: "文件.pdf",
                typeIdentifier: "com.adobe.pdf", byteCount: 3, thumbnailURL: try file("document.jpg")))
            var link = LinkAttachment(url: URL(string: "https://example.com")!, title: "Example")
            link.imageURL = try self.file("link.jpg")
            link.iconURL = try self.file("icon.png")
            let media = try (0..<4).map { index in
                MediaItem(assetIdentifier: "asset-\(index)", originalFileURL: try self.file("original-\(index).dat"),
                    thumbnailFileURL: try self.file("thumbnail-\(index).jpg"), pixelSize: CGSize(width: 320, height: 180),
                    kind: index == 3 ? .video(duration: 3.5) : .image, isAnimatedImage: index == 1,
                    livePhotoVideoURL: index == 2 ? try self.file("live.mov") : nil)
            }
            return .init(conversationID: "chat", segments: [
                .richText(.init(runs: [.init("  中文👨‍👩‍👧‍👦\n", style: [.bold, .underline])])),
                .attachment(file.id), .text("\n  "), .attachment(link.id), .text("مرحبا\n")
            ], documents: [file, .link(link)], media: .init(items: media),
                audio: .init(fileURL: try self.file("voice.m4a"), duration: 3.2, waveform: [0.1, 0.9], transcript: "你好"))
        }
        /// 创建使用测试草稿存储与独立页面附件目录的聊天控制器，不自动加载视图。
        ///
        /// - Returns: 会话标识为 `chat` 的页面，可等待其恢复任务验证控制器接入。
        @available(iOS 26.0, *)
        func controller() -> ChatViewController {
            let page = PageAttachmentStore(parentDirectory: root)
            return ChatViewController(viewModel: ChatViewModel(), audioController: AudioController(attachmentStore: page),
                                      conversationID: "chat", draftStore: store)
        }
    }
}
