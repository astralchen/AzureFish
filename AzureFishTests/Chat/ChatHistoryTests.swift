import AppLocalization
import AVFAudio
import PDFKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatHistoryTests {
    @Test func completeHistoryHasRealResourcesAndNoSendSideEffects() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let samples = try await SampleChatHistory.load(store: store)
        let model = ChatViewModel()
        #expect(model.messages.isEmpty && model.state.timeline.isEmpty)
        #expect(model.nextMessageID == 0)
        model.insertInitialHistory(samples)
        #expect(samples.count == 38)
        #expect(model.messages.count == 38)
        #expect(model.nextMessageID == 38)
        #expect(model.messages.filter { $0.direction == .outgoing }.count == 19)
        #expect(model.messages.allSatisfy { $0.deliveryState == ($0.direction == .outgoing ? .read : nil) })
        #expect(model.sendTasks.isEmpty && model.pendingReplies.isEmpty && model.pendingReplyTask == nil)
        #expect(!model.state.isProcessingMessages && !model.state.isTyping)
        #expect(Set(model.messages.map(\.id)).count == 38)
        var media: [MediaItem] = []
        var attachmentIDs: [UUID] = []
        var files: Set<URL> = []
        for sample in samples {
            switch sample.content {
            case .userText(let text):
                #expect(!text.isEmpty)
            case .richText(let text):
                #expect(text.runs.contains { $0.style == [.bold, .italic, .underline] })
                #expect(text.runs.contains { $0.style == .strikethrough })
            case .attachment(let attachment):
                attachmentIDs.append(attachment.id)
                for url in attachment.localFileURLs {
                    #expect(url.path.hasPrefix(store.directoryURL.path + "/"))
                    #expect(FileManager.default.isReadableFile(atPath: url.path))
                    files.insert(url)
                }
                switch attachment {
                case .audio(let audio):
                    let player = try AVAudioPlayer(contentsOf: audio.fileURL)
                    #expect(abs(player.duration - audio.duration) < 0.01)
                    #expect(audio.duration > 1 && audio.waveform.contains { $0 > 0.08 })
                    #expect(audio.transcript?.contains("语音消息") == true)
                case .file(let file):
                    #expect((PDFDocument(url: file.fileURL)?.pageCount ?? 0) > 0)
                    #expect(file.byteCount > 0)
                case .mediaGroup(let group): media += group.items
                case .link(let link):
                    #expect(LinkAttachment.accepts(link.url) && link.title != nil)
                    #expect(link.imageURL == nil && link.iconURL == nil)
                }
            default: Issue.record("Unexpected sample history content")
            }
        }
        #expect(Set(attachmentIDs).count == 14)
        #expect(media.count == 8 && Set(media.map(\.id)).count == 8)
        #expect(media.filter(\.isLivePhoto).count == 2)
        #expect(media.filter(\.isAnimatedImage).count == 2)
        #expect(media.filter { $0.kind.isVideo }.count == 2)
        #expect(media.allSatisfy { !($0.isLivePhoto && $0.isAnimatedImage) })
        model.insertInitialHistory(samples)
        #expect(model.messages.count == 38)
        store.removeAll()
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func loadingPreservesNewMessagesAndTheirIDs() async throws {
        guard #available(iOS 26.0, *) else { return }
        let model = ChatViewModel()
        #expect(model.send("sent during loading"))
        let sent = try #require(model.messages.last)
        let store = PageAttachmentStore()
        defer { store.removeAll(); model.cancelPendingReply() }
        let samples = try await SampleChatHistory.load(store: store)
        model.insertInitialHistory(samples)
        #expect(model.messages[38].id == sent.id)
        #expect(model.messages[38].content == sent.content)
        #expect(Set(model.messages.map(\.id)).count == model.messages.count)
        #expect(model.messages.map(\.sentAt) == model.messages.map(\.sentAt).sorted())
        let nextID = model.nextMessageID
        #expect(model.send("sent after loading"))
        #expect(model.messages.last?.id == nextID)
    }

    @Test func partialLivePhotoFailureRemovesOrphansAndKeepsOtherTypes() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = InterceptingStore()
        defer { store.removeAll() }
        store.rejectedName = "live-photo.mov"
        let samples = try await SampleChatHistory.load(store: store)
        #expect(samples.count == 36)
        let referenced = Set(samples.flatMap { sample -> [URL] in
            if case .attachment(let attachment) = sample.content { return attachment.localFileURLs }
            return []
        })
        let actual = try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)
        #expect(Set(actual) == referenced)
    }

    @Test func cancellationAfterImportRemovesAllPartialFiles() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = InterceptingStore()
        defer { store.removeAll() }
        var task: Task<[MessageHistoryEntry], Error>?
        var importCount = 0
        store.imported = {
            importCount += 1
            if importCount == 2 { task?.cancel() }
        }
        task = Task { try await SampleChatHistory.load(store: store) }
        do {
            _ = try await task!.value
            Issue.record("Cancelled history should not be inserted")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
    }

    @Test func onlyOrdinaryEntryLoadsInitialHistory() async throws {
        guard #available(iOS 26.0, *) else { return }
        #expect(SampleChatHistory.isEnabled(arguments: []))
        for argument in ["-imessage-save-fixture", "preview-video", "-media-benchmark", "-imessage-basic-history"] {
            #expect(!SampleChatHistory.isEnabled(arguments: [argument]))
        }
        let injected = ChatViewController(viewModel: ChatViewModel())
        injected.loadViewIfNeeded()
        #expect(injected.viewModel.messages.isEmpty)
        for _ in 0..<2 {
            let page = ChatViewController()
            page.loadViewIfNeeded()
            for _ in 0..<150 where page.viewModel.messages.count != 38 {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(page.viewModel.messages.count == 38)
            #expect(page.viewModel.sendTasks.isEmpty)
        }
    }

    @Test func leavingBeforeLoadCompletesCannotAppendHistory() async throws {
        guard #available(iOS 26.0, *) else { return }
        var page: ChatViewController? = ChatViewController()
        let pageWasReleased = { [weak page] in page == nil }
        let model = page!.viewModel
        let directory = page!.attachmentStore.directoryURL
        page!.loadViewIfNeeded()
        page = nil
        for _ in 0..<50 where !pageWasReleased() || FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(pageWasReleased())
        #expect(model.messages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func historyInsertionKeepsAnchorAndSendingStillReachesBottom() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        let conversation = ConversationView(frame: window.bounds)
        host.view = conversation
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let model = ChatViewModel()
        let now = Date()
        model.messages += (0..<45).map {
            Message(id: $0, direction: .incoming, content: .userText("History \($0)\nSecond line"),
                    sentAt: now, deliveryState: nil)
        }
        model.nextMessageID = 45
        model.state = model.makeState()
        model.bind { state, reason in conversation.render(state, reason: reason) }
        let list = conversation.collectionView
        #expect(await eventually {
            conversation.layoutIfNeeded()
            list.layoutIfNeeded()
            return list.numberOfItems(inSection: 0) == model.state.timeline.count
                && !list.visibleCells.isEmpty && list.contentSize.height > list.bounds.height
                && list.alpha == 1 && conversation.isNearBottom
        })
        conversation.scrollViewWillBeginDragging(list)
        list.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        list.layoutIfNeeded()
        #expect(await eventually { !list.indexPathsForVisibleItems.isEmpty })
        let index = try #require(list.indexPathsForVisibleItems.sorted().first)
        let id = model.state.timeline[index.item].id
        let beforeY = try #require(list.layoutAttributesForItem(at: index)).frame.minY - list.contentOffset.y
        model.insertInitialHistory((0..<16).map { _ in
            .init(direction: .incoming, content: .userText("Earlier history\nSecond line"))
        })
        let newIndex = try #require(model.state.timeline.firstIndex { $0.id == id })
        #expect(await eventually {
            list.layoutIfNeeded()
            guard list.numberOfItems(inSection: 0) == model.state.timeline.count,
                  let attributes = list.layoutAttributesForItem(at: IndexPath(item: newIndex, section: 0)) else { return false }
            return abs(attributes.frame.minY - list.contentOffset.y - beforeY) < 2
        })
        defer { model.cancelPendingReply() }
        #expect(model.send("Sent from long history"))
        let sentID = model.messages.last?.id
        #expect(await eventually {
            conversation.layoutIfNeeded()
            list.layoutIfNeeded()
            return model.messages.first(where: { $0.id == sentID })?.deliveryState == .read
                && conversation.isNearBottom && list.visibleCells.contains {
                ($0 as? TextBubbleCell)?.bubbleView.accessibilityLabel == "Sent from long history"
            }
        })
    }

    /// 逐次采样可见帧，而非仅等待最终 isNearBottom；同时覆盖数据先到和视口先到。
    @Test(arguments: [0, 1, 60])
    func firstVisibleHistoryIsAlreadyAtBottom(messageCount: Int) async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        let conversation = ConversationView()
        host.view = conversation
        window.rootViewController = host
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let model = ChatViewModel()
        conversation.initialPresentation.waitForHistory(in: conversation)
        model.bind { state, reason in conversation.render(state, reason: reason) }
        if messageCount != 1 { window.makeKeyAndVisible() }
        // 首次空快照已经提交，也不能在历史结果之前提前展示。
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(conversation.collectionView.alpha == 0)
        model.insertInitialHistory((0..<messageCount).map { index in
            .init(direction: .incoming,
                  content: .userText("History \(index)\n" + String(repeating: "Variable height line\n", count: index % 8)))
        })
        // 同一批历史紧接局部刷新，过期提交不得显示旧内容或丢失首次定位。
        conversation.render(model.state, reason: .messageStatus)
        if messageCount == 1 { window.makeKeyAndVisible() }
        let list = conversation.collectionView
        var visibleSamples = 0
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            guard list.alpha == 1 else { continue }
            visibleSamples += 1
            let bottom = max(-list.adjustedContentInset.top,
                             list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            #expect(abs(list.contentOffset.y - bottom) < 1)
            #expect(!list.accessibilityElementsHidden)
            if messageCount > 0 {
                #expect(list.indexPathsForVisibleItems.contains(IndexPath(item: model.state.timeline.count - 1, section: 0)))
            }
            if visibleSamples == 12 { break }
        }
        #expect(visibleSamples == 12, "初始内容必须可见，且每次可见采样均已位于底部")
        // 临时离开窗口再回来，不能重新隐藏或重置用户阅读位置。
        if messageCount == 60 {
            conversation.scrollViewWillBeginDragging(list)
            list.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
            list.layoutIfNeeded()
            let offset = list.contentOffset
            window.isHidden = true
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 100_000_000)
            #expect(list.alpha == 1)
            #expect(abs(list.contentOffset.y - offset.y) < 1)
        }
    }

    @Test(arguments: [false, true])
    func waitingHistoryCanFinishWithFailureOrEarlySend(sendsMessage: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        let conversation = ConversationView()
        host.view = conversation
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let model = ChatViewModel()
        defer { model.cancelPendingReply() }
        conversation.initialPresentation.waitForHistory(in: conversation)
        model.bind { state, reason in conversation.render(state, reason: reason) }
        if sendsMessage {
            #expect(model.send("Sent while loading"))
        } else {
            conversation.initialPresentation.finishWaitingForHistory()
        }
        #expect(await eventually { conversation.collectionView.alpha == 1 })
        #expect(conversation.subviews.compactMap { $0 as? UIActivityIndicatorView }.isEmpty)
    }

    @Test func normalEntryKeepsEveryVisibleFrameAtBottom() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let page = ChatViewController()
        let list = page.conversationView.collectionView
        var visibleFrames = 0
        let probe = ChatInitialFrameProbe {
            guard list.window != nil, list.alpha == 1 else { return }
            visibleFrames += 1
            let bottom = max(-list.adjustedContentInset.top,
                             list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom)
            #expect(abs(list.contentOffset.y - bottom) < 1, "首次展示后每帧都应保持最终底部")
            #expect(page.viewModel.messages.count == 38)
            if visibleFrames == 1 || visibleFrames == 20 {
                let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try? capture.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("chat-initial-visible-\(visibleFrames).png"))
            }
        }
        probe.start()
        defer { probe.stop() }
        navigation.pushViewController(page, animated: true)
        #expect(await eventually { visibleFrames >= 30 })
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

/// 按实际刷新节奏观察列表；测试不调用 layoutIfNeeded 或滚动来帮助被测页面通过。
@MainActor
private final class ChatInitialFrameProbe: NSObject {
    private let sample: () -> Void
    private var link: CADisplayLink?
    init(sample: @escaping () -> Void) { self.sample = sample }
    func start() {
        link = CADisplayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func tick() { sample() }
}

/// 在真实页面目录上注入部分导入失败或取消，检查实际文件回收。
@MainActor
private final class InterceptingStore: AttachmentStoring {
    let base = PageAttachmentStore()
    var rejectedName: String?
    var imported: (() -> Void)?
    var directoryURL: URL { base.directoryURL }
    func makeFileURL(prefix: String, pathExtension: String) -> URL {
        base.makeFileURL(prefix: prefix, pathExtension: pathExtension)
    }
    func importFile(at sourceURL: URL, prefix: String, pathExtension: String?) throws -> URL {
        if sourceURL.lastPathComponent == rejectedName { throw CocoaError(.fileReadNoSuchFile) }
        let url = try base.importFile(at: sourceURL, prefix: prefix, pathExtension: pathExtension)
        imported?()
        return url
    }
    func registerDraft(_ attachment: AzureFish.Attachment) { base.registerDraft(attachment) }
    func registerCommitted(_ attachment: AzureFish.Attachment) { base.registerCommitted(attachment) }
    func commitDraft(id: UUID) -> Bool { base.commitDraft(id: id) }
    func discardDraft(id: UUID) { base.discardDraft(id: id) }
    func removeFile(at url: URL) { base.removeFile(at: url) }
    func removeAll() { base.removeAll() }
}
