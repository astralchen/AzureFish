import AVFoundation
import CoreVideo
import Foundation
import QuickLayoutKit
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatPasteTests {
    @Test func realWindowPureURLPasteReplacesSelectionAndKeepsFocus() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let store = PageAttachmentStore()
        let page = ChatViewController(viewModel: ChatViewModel(), audioController: AudioController(attachmentStore: store))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        let pasteboard = UIPasteboard.general
        let original = pasteboard.items
        pasteboard.string = "https://example.invalid/path"
        let change = pasteboard.changeCount
        defer {
            page.composerView.textView.resignFirstResponder()
            window.isHidden = true
            previous?.makeKey()
            if pasteboard.changeCount == change { pasteboard.items = original }
            page.documentController.discardAll(); page.viewModel.cancelPendingReply(); store.removeAll()
        }
        let composer = page.composerView
        composer.textView.text = "Keep"
        composer.textViewDidChange(composer.textView)
        page.view.layoutIfNeeded()
        try #require(composer.textView.becomeFirstResponder())
        composer.textView.selectedRange = NSRange(location: 1, length: 2)
        composer.textView.paste(nil)
        try await waitUntil {
            composer.orderedDocumentIDs.count == 1 && composer.textView.selectedRange == NSRange(location: 4, length: 0)
        }
        let id = try #require(composer.orderedDocumentIDs.first)
        guard case .link(let link) = page.documentController.drafts[id]?.attachment else { Issue.record("Native URL paste did not become a link"); return }
        #expect(link.url.absoluteString == "https://example.invalid/path")
        #expect(composer.plainDraftText == "Kp")
        #expect(composer.textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(composer.textView.isFirstResponder)
    }

    @Test func realWindowPasteCombinesMediaTokensInUIKitOrderAndKeepsMixedText() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let model = ChatViewModel()
        let page = ChatViewController(viewModel: model, audioController: AudioController(attachmentStore: store))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = page
        window.makeKeyAndVisible()
        let pasteboard = UIPasteboard.general
        let originalItems = pasteboard.items
        var ownedPasteboardChange: Int?
        defer {
            page.composerView.textView.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            // 仅恢复本测试写入的剪贴板；测试期间用户复制的新内容应当保留。
            if pasteboard.changeCount == ownedPasteboardChange { pasteboard.items = originalItems }
            page.documentController.discardAll(); model.cancelPendingReply()
            store.removeAll(); files.remove()
        }
        let image = try files.image()
        let movie = try await files.video()
        let audio = try files.audio()
        let document = try files.document("real-paste")
        let composer = page.composerView
        let textView = composer.textView
        textView.text = "前🙂选中后"
        composer.textViewDidChange(textView)
        page.view.layoutIfNeeded()
        try #require(textView.becomeFirstResponder())
        textView.selectedRange = (textView.text as NSString).range(of: "选中")
        var batches: [[DocumentDraft]] = []
        let originalInsert = page.documentController.contentsInserted
        page.documentController.contentsInserted = { contents in
            batches.append(contents.compactMap { if case .attachment(let draft) = $0 { return draft }; return nil })
            originalInsert?(contents)
        }
        pasteboard.itemProviders = [
            files.provider(url: image, type: .png),
            NSItemProvider(object: "插入 https://example.invalid 正文" as NSString),
            files.provider(url: movie, type: .quickTimeMovie),
            files.provider(url: audio, type: .wav),
            files.provider(url: document, type: .json),
        ]
        ownedPasteboardChange = pasteboard.changeCount
        // 本测试的唯一粘贴入口：UIKit 自己调用 transform、组合 Token 并执行 performPasteOf。
        textView.paste(nil)
        do {
            try await waitUntil { composer.orderedDocumentIDs.count == 4 }
        } catch {
            Issue.record("Mixed paste state: batches=\(batches.map { $0.count }), ids=\(composer.orderedDocumentIDs), drafts=\(page.documentController.drafts.count), range=\(textView.selectedRange), text=\(textView.text.debugDescription)")
            throw error
        }
        let ids = composer.orderedDocumentIDs
        #expect(batches.count == 1)
        #expect(batches.first?.map(\.id) == ids)
        let body = "前🙂插入 https://example.invalid 正文后"
        #expect(composer.plainDraftText == body)
        #expect(textView.isFirstResponder)
        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length - 1, length: 0))
        #expect(composer.draftSegments == [
            .text("前🙂"), .attachment(ids[0]), .text("插入 https://example.invalid 正文"),
            .attachment(ids[1]), .attachment(ids[2]), .attachment(ids[3]), .text("后")
        ])
        let selection = textView.selectedRange
        try await waitUntil { ids.allSatisfy { page.documentController.drafts[$0]?.status != .importing } }
        let attachments = try #require(page.documentController.attachments(for: ids))
        try #require(attachments.count == 4)
        guard case .mediaGroup(let imageGroup) = attachments[0],
              case .mediaGroup(let videoGroup) = attachments[1],
              case .file(let audioFile) = attachments[2],
              case .file(let documentFile) = attachments[3] else {
            Issue.record("UIKit paste changed provider order or lost an attachment token"); return
        }
        #expect(imageGroup.items.count == 1)
        #expect(imageGroup.items.first?.kind == .image)
        #expect(videoGroup.items.count == 1)
        #expect(videoGroup.items.first?.kind.isVideo == true)
        #expect(imageGroup.id != videoGroup.id)
        #expect(UTType(audioFile.typeIdentifier)?.conforms(to: .audio) == true)
        #expect(documentFile.typeIdentifier == UTType.json.identifier)
        #expect(composer.orderedDocumentIDs == ids)
        #expect(textView.selectedRange == selection)
        page.view.layoutIfNeeded()
        textView.setContentOffset(.zero, animated: false)
        let snapshot = UIGraphicsImageRenderer(bounds: page.view.bounds).image { _ in
            page.view.drawHierarchy(in: page.view.bounds, afterScreenUpdates: true)
        }
        try snapshot.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("imessage-real-paste-media.png"))
        let initialIDs = Set(messages(model).map(\.id))
        composer.sendButton.sendActions(for: .touchUpInside)
        var expected: [MessagePresentationContent] = [.text("前🙂"), .attachment(attachments[0]), .text("插入 https://example.invalid 正文")]
        expected.append(contentsOf: attachments.dropFirst().map { .attachment($0) })
        expected.append(.text("后"))
        #expect(messages(model).filter { !initialIDs.contains($0.id) }.map(\.content) == expected)
        #expect(composer.orderedDocumentIDs.isEmpty)
        #expect(composer.plainDraftText.isEmpty)
    }

    @Test func deleteButtonHasIndependentTouchAreaAndVoiceOverActionInBothDirections() throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        defer { files.remove() }
        let image = try files.image()
        let media = MediaItem(assetIdentifier: nil, originalFileURL: image,
            thumbnailFileURL: image, pixelSize: CGSize(width: 64, height: 48), kind: .video(duration: 12))
        let card = AttachmentCard(frame: .zero)
        var deletions = 0
        var opens = 0
        card.open = { opens += 1 }
        card.remove = { deletions += 1 }
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            card.semanticContentAttribute = direction
            card.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            card.configure(.init(attachment: .mediaGroup(.init(items: [media]))))
            card.frame = CGRect(x: 0, y: 0, width: 310, height: TextAttachment.height(for: card.traitCollection))
            card.setNeedsQuickLayout()
            card.layoutIfNeeded()
            let button = try #require(descendants(card).compactMap { $0 as? DraftRemoveButton }.first { $0.accessibilityIdentifier == "imessage.attachment.remove" })
            #expect(button.bounds.width >= 44 && button.bounds.height >= 44)
            let frame = button.convert(button.bounds, to: card)
            #expect(frame.maxX <= card.bounds.maxX && frame.maxX >= card.bounds.maxX - 8)
            #expect(frame.minY <= 8)
            #expect(card.accessibilityCustomActions?.count == 2)
            #expect(card.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil) === button)
            button.sendActions(for: .touchUpInside)
        }
        #expect(deletions == 2)
        #expect(opens == 0)
        card.remove = nil
        card.layoutIfNeeded()
        #expect(card.accessibilityCustomActions?.count == 1)
        #expect(!descendants(card).contains { $0.accessibilityIdentifier == "imessage.attachment.remove" && !$0.isHidden })
    }

    @available(iOS 26.0, *)
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @Test func webURLRequiresAnEntireHTTPOrHTTPSValue() {
        guard #available(iOS 26.0, *) else { return }
        for value in ["https://example.invalid/path?q=1#part", "http://example.invalid", " \nhttps://example.invalid/a\t"] {
            #expect(PasteSource.webURL(in: value)?.absoluteString == value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for value in ["", " \n", "见 https://example.invalid", "https://example.invalid 后文",
                      "https://example.invalid\nhttps://other.invalid", "file:///tmp/a.pdf",
                      "mailto:a@example.invalid", "javascript:alert(1)", "example.invalid", "https://"] {
            #expect(PasteSource.webURL(in: value) == nil, "Unexpected link: \(value)")
        }
    }

    @Test func realWindowBatchInsertionReplacesMarkedSelectionWithoutDuplicatingComposition() throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        let composer = makeComposer(text: "前文后文")
        composer.frame.origin.y = 120
        root.view.addSubview(composer)
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.setNeedsQuickLayout()
        composer.layoutIfNeeded()
        defer {
            composer.textView.unmarkText()
            composer.textView.resignFirstResponder()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        let textView = composer.textView
        try #require(textView.becomeFirstResponder())
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.setMarkedText("nihao", selectedRange: NSRange(location: 1, length: 3))
        try #require(textView.markedTextRange != nil)
        let drafts = ["https://first.invalid", "https://second.invalid"].map {
            DocumentDraft(attachment: .link(.init(url: URL(string: $0)!)))
        }
        composer.insertContents(drafts.map { .attachment($0) })
        #expect(composer.orderedDocumentIDs == drafts.map(\.id))
        #expect(textView.markedTextRange == nil)
        #expect(composer.plainDraftText == "前文no后文")
        #expect(composer.draftSegments == [.text("前文n"), .attachment(drafts[0].id), .attachment(drafts[1].id), .text("o后文")])
        #expect(textView.selectedRange == NSRange(location: textView.textStorage.length - 3, length: 0))
        #expect(textView.isFirstResponder)
    }

    @Test func fileTypeDistinguishesMediaDocumentsAndOrdinaryText() {
        guard #available(iOS 26.0, *) else { return }
        for type in [UTType.png, .quickTimeMovie, .wav, .pdf, .json] {
            #expect(PasteSource.fileType(in: dataProvider(type)) == type.identifier)
        }
        let movieWithPoster = dataProvider(.png)
        registerData(on: movieWithPoster, type: .quickTimeMovie)
        #expect(PasteSource.fileType(in: movieWithPoster) == UTType.quickTimeMovie.identifier)
        let documentWithPreview = dataProvider(.png)
        registerData(on: documentWithPreview, type: .pdf)
        #expect(PasteSource.fileType(in: documentWithPreview) == UTType.pdf.identifier)
        for type in [UTType.plainText, .url, .fileURL, .html, .rtf, .rtfd, .data] {
            #expect(PasteSource.fileType(in: dataProvider(type)) == nil, "Unexpected file: \(type)")
        }
        let namedText = dataProvider(.plainText)
        namedText.suggestedName = "Notes.txt"
        #expect(PasteSource.fileType(in: namedText) == UTType.plainText.identifier)
        #expect(PasteSource.fileType(in: NSItemProvider(object: "正文" as NSString)) == nil)
    }

    @Test func installedPasteDelegateTurnsOnlyPureURLsIntoCards() async throws {
        guard #available(iOS 26.0, *) else { return }
        for (value, isLink) in [(" \nhttps://example.invalid/path\t", true),
                                ("前文 https://example.invalid/path 后文", false),
                                ("第一行\nhttps://example.invalid/path\n末行", false)] {
            let composer = makeComposer(text: "左选中右")
            composer.textView.selectedRange = NSRange(location: 1, length: 2)
            var batches: [[PasteSource]] = []
            composer.pasteAttachments = { batches.append($0) }
            try await paste([NSItemProvider(object: value as NSString)], into: composer)
            if isLink {
                let batch = try #require(batches.first)
                #expect(batches.count == 1)
                #expect(batch.count == 1)
                guard case .link(let url) = try #require(batch.first) else {
                    Issue.record("Pure URL did not become a link source"); return
                }
                #expect(url.absoluteString == "https://example.invalid/path")
                #expect(composer.plainDraftText == "左选中右")
                #expect(composer.textView.selectedRange == NSRange(location: 1, length: 2))
            } else {
                #expect(batches.isEmpty)
                #expect(composer.plainDraftText == "左\(value)右")
                #expect(composer.textView.selectedRange == NSRange(location: 1 + (value as NSString).length, length: 0))
            }
        }
    }

    @Test func delegatePreservesProviderIdentityTypeAndFileURL() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixtures = PasteFiles()
        defer { fixtures.remove() }
        let file = try fixtures.document("local")
        let types: [UTType] = [.png, .quickTimeMovie, .wav, .pdf]
        let providers = types.map { dataProvider($0) }
        let composer = makeComposer(text: "保留正文")
        var received: [PasteSource] = []
        var calls = 0
        composer.pasteAttachments = { received = $0; calls += 1 }
        let fileProvider = dataProvider(.fileURL, data: Data(file.absoluteString.utf8))
        try await paste(providers + [fileProvider], into: composer)
        #expect(calls == 1)
        try #require(received.count == providers.count + 1)
        for index in providers.indices {
            guard case .provider(let provider, let identifier) = received[index] else {
                Issue.record("Media/document provider was flattened into text"); return
            }
            #expect(provider === providers[index])
            #expect(identifier == types[index].identifier)
        }
        guard case .fileURL(let url) = received[providers.count] else {
            Issue.record("File URL was treated as a web link or text"); return
        }
        #expect(url == file)
        #expect(composer.plainDraftText == "保留正文")
    }

    @Test func mixedProviderBatchPreservesInterleavedSourcesForOneReplacement() async throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer(text: "左选中右")
        composer.textView.selectedRange = NSRange(location: 1, length: 2)
        var batches: [[PasteSource]] = []
        composer.pasteAttachments = { batches.append($0) }
        let image = dataProvider(.png)
        let document = dataProvider(.pdf)
        try await paste([image, NSItemProvider(object: "含 https://example.invalid 的正文" as NSString), document], into: composer)
        let batch = try #require(batches.first)
        #expect(batches.count == 1)
        try #require(batch.count == 3)
        guard case .provider(let first, _) = batch[0], case .text(let body) = batch[1], case .provider(let second, _) = batch[2] else {
            Issue.record("Mixed paste lost its attachment tokens"); return
        }
        #expect(first === image)
        #expect(second === document)
        #expect(body == "含 https://example.invalid 的正文")
        #expect(composer.plainDraftText == "左选中右")
        #expect(!composer.textView.text.contains("\u{FFFC}"))
    }

    @Test func batchReplacementKeepsClipboardOrderAndUTF16CaretDespiteReverseCompletion() async throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let controller = DocumentController(store: store)
        let composer = makeComposer(text: "前🙂选中后")
        let first = try files.document("first")
        let second = try files.document("second")
        let gates = [PasteFileGate(url: first), PasteFileGate(url: second)]
        defer {
            controller.discardAll()
            controller.contentsInserted = nil
            controller.draftUpdated = nil
            composer.pasteAttachments = nil
            gates.forEach { $0.failIfPending() }
            store.removeAll(); files.remove()
        }
        let existing = DocumentDraft(attachment: .link(.init(url: URL(string: "https://existing.invalid")!)))
        composer.textView.selectedRange = NSRange(location: 0, length: 0)
        composer.insertDocument(existing)
        let selected = (composer.textView.text as NSString).range(of: "🙂选中")
        composer.textView.selectedRange = selected
        let originalLength = composer.textView.textStorage.length
        var batches: [[DocumentDraft]] = []
        var updates: [UUID] = []
        controller.contentsInserted = { contents in
            let drafts = contents.compactMap { if case .attachment(let draft) = $0 { return draft }; return nil }
            // 回调发生时整批身份必须已经注册，发送仍须等待导入。
            #expect(drafts.allSatisfy { controller.drafts[$0.id] == $0 })
            batches.append(drafts)
            composer.insertContents(contents)
        }
        controller.draftUpdated = { draft in updates.append(draft.id); composer.updateDocument(draft) }
        composer.pasteAttachments = { controller.insertPasted($0) }
        try await paste(gates.map { $0.provider(type: .json) }, into: composer)
        let batch = try #require(batches.first)
        try #require(batch.count == 2)
        #expect(batches.count == 1)
        #expect(batch.allSatisfy { $0.status == .importing })
        #expect(controller.attachments(for: batch.map(\.id)) == nil)
        #expect(composer.orderedDocumentIDs == [existing.id] + batch.map(\.id))
        let shifted = NSRange(location: selected.location + composer.textView.textStorage.length - originalLength + selected.length, length: 0)
        #expect(composer.textView.selectedRange == shifted)
        #expect((composer.textView.text as NSString).substring(from: shifted.location) == "后")
        try await waitUntil { gates.allSatisfy(\.started) }
        gates[1].succeed()
        try await waitUntil { controller.drafts[batch[1].id]?.status == .ready }
        #expect(controller.drafts[batch[0].id]?.status == .importing)
        #expect(updates.first == batch[1].id)
        gates[0].succeed()
        try await waitUntil { controller.drafts[batch[0].id]?.status == .ready }
        #expect(composer.orderedDocumentIDs == [existing.id] + batch.map(\.id))
        #expect(composer.textView.selectedRange == shifted)
        #expect(composer.plainDraftText == "前后")
        let imported = try #require(controller.attachments(for: batch.map(\.id)))
        for (attachment, source) in zip(imported, [first, second]) {
            guard case .file(let file) = attachment else { Issue.record("JSON must remain a file"); return }
            #expect(file.fileURL != source)
            #expect(try Data(contentsOf: file.fileURL) == Data(contentsOf: source))
        }
    }

    @Test func imageAndVideoImportAsSeparateMediaGroupsThenSendInPasteOrder() async throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let model = ChatViewModel()
        let page = ChatViewController(viewModel: model, audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        defer { page.documentController.discardAll(); model.cancelPendingReply(); store.removeAll(); files.remove() }
        let image = try files.image()
        let video = try await files.video()
        let audio = try files.audio()
        let document = try files.document("payload")
        let urls = [image, video, audio, document]
        let types: [UTType] = [.png, .quickTimeMovie, .wav, .json]
        let composer = page.composerView
        composer.textView.text = "附件之后的正文"
        composer.textViewDidChange(composer.textView)
        let initialIDs = Set(messages(model).map(\.id))
        // 保留页面本身的 paste -> controller -> composer 与 sendButton -> ViewModel 接线。
        try await paste(zip(urls, types).map { files.provider(url: $0.0, type: $0.1) }, into: composer)
        let ids = composer.orderedDocumentIDs
        try #require(ids.count == 4)
        #expect(page.documentController.attachments(for: ids) == nil)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(Set(messages(model).map(\.id)) == initialIDs)
        #expect(composer.plainDraftText == "附件之后的正文")
        try await waitUntil {
            ids.allSatisfy { page.documentController.drafts[$0]?.status != .importing }
        }
        let attachments = try #require(page.documentController.attachments(for: ids))
        try #require(attachments.count == 4)
        guard case .mediaGroup(let imageGroup) = attachments[0],
              case .mediaGroup(let videoGroup) = attachments[1],
              case .file(let audioFile) = attachments[2],
              case .file(let documentFile) = attachments[3] else {
            Issue.record("Expected independent image/video groups followed by audio/document files"); return
        }
        #expect(imageGroup.id == ids[0])
        #expect(videoGroup.id == ids[1])
        #expect(imageGroup.id != videoGroup.id)
        try #require(imageGroup.items.count == 1 && videoGroup.items.count == 1)
        #expect(imageGroup.items[0].kind == .image)
        #expect(imageGroup.items[0].pixelSize == CGSize(width: 64, height: 48))
        #expect(videoGroup.items[0].kind.isVideo)
        #expect((videoGroup.items[0].kind.duration ?? 0) > 0)
        #expect(videoGroup.items[0].pixelSize == CGSize(width: 64, height: 48))
        for item in [imageGroup.items[0], videoGroup.items[0]] {
            #expect(UIImage(contentsOfFile: item.thumbnailFileURL.path) != nil)
            #expect(item.originalFileURL != item.thumbnailFileURL)
            #expect(item.originalFileURL.deletingLastPathComponent() == store.directoryURL)
        }
        #expect(UTType(audioFile.typeIdentifier)?.conforms(to: .audio) == true)
        #expect(documentFile.typeIdentifier == UTType.json.identifier)
        #expect(audioFile.byteCount == Int64(try Data(contentsOf: audio).count))
        #expect(try Data(contentsOf: documentFile.fileURL) == Data(contentsOf: document))
        #expect(composer.orderedDocumentIDs == ids)
        let ownedURLs = attachments.flatMap(\.localFileURLs)
        for url in urls { try FileManager.default.removeItem(at: url) }
        #expect(ownedURLs.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
        composer.sendButton.sendActions(for: .touchUpInside)
        let sent = messages(model).filter { !initialIDs.contains($0.id) }
        #expect(sent.map(\.content) == [.text("附件之后的正文")] + attachments.map { .attachment($0) })
        #expect(composer.orderedDocumentIDs.isEmpty)
        #expect(composer.plainDraftText.isEmpty)
        #expect(page.documentController.drafts.isEmpty)
        page.documentController.discardAll()
        #expect(ownedURLs.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
    }

    @Test func deletingBeforeImportTaskStartsDoesNotRequestProviderData() async throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let controller = DocumentController(store: store)
        let gate = PasteFileGate(url: try files.document("never-start"))
        defer { gate.failIfPending(); controller.discardAll(); store.removeAll(); files.remove() }
        controller.insertPasted([.provider(gate.provider(type: .json), typeIdentifier: UTType.json.identifier)])
        let id = try #require(controller.drafts.keys.first)
        controller.remove(id)
        for _ in 0..<20 { await Task.yield() }
        #expect(!gate.started)
        #expect(controller.drafts.isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(at: store.directoryURL, includingPropertiesForKeys: nil)).isEmpty)
    }

    @Test func deletingPendingCardCancelsProviderAndCannotResurrectOnLateCompletion() async throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let model = ChatViewModel()
        let page = ChatViewController(viewModel: model, audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        let source = try files.image()
        let gate = PasteFileGate(url: source)
        defer {
            page.documentController.discardAll(); gate.failIfPending()
            model.cancelPendingReply(); store.removeAll(); files.remove()
        }
        let composer = page.composerView
        composer.textView.text = "删除附件也保留正文"
        composer.textViewDidChange(composer.textView)
        var updates: [UUID] = []
        let originalUpdate = page.documentController.draftUpdated
        page.documentController.draftUpdated = { draft in updates.append(draft.id); originalUpdate?(draft) }
        try await paste([gate.provider(type: .png)], into: composer)
        let id = try #require(composer.orderedDocumentIDs.first)
        try await waitUntil { gate.started }
        #expect(page.documentController.drafts[id]?.status == .importing)
        // 通过 TextKit 删除真实卡片，触发生产代码的 removeDocument action。
        var cardRange: NSRange?
        composer.textView.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: composer.textView.textStorage.length)) { value, range, _ in
            if value is TextAttachment { cardRange = range }
        }
        composer.textView.textStorage.deleteCharacters(in: try #require(cardRange))
        composer.textViewDidChange(composer.textView)
        try await waitUntil { gate.cancelled }
        #expect(page.documentController.drafts[id] == nil)
        gate.succeed() // 供应方在取消后仍返回有效文件，不能把卡片或文件重新留下。
        try await waitUntil { gate.delivered }
        // 私有导入 Task 没有 await 接口；为迟到 continuation 与清理留出明确观察窗口。
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(updates.isEmpty)
        #expect(composer.orderedDocumentIDs.isEmpty)
        #expect(page.documentController.drafts.isEmpty)
        #expect(composer.plainDraftText == "删除附件也保留正文")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path).isEmpty)
        #expect(FileManager.default.isReadableFile(atPath: source.path))
    }

    @Test func corruptImageFailsWithoutLosingBodyAndRemovingItAllowsRemainingFileToSend() async throws {
        guard #available(iOS 26.0, *) else { return }
        let files = PasteFiles()
        let store = PageAttachmentStore()
        let model = ChatViewModel()
        let page = ChatViewController(viewModel: model, audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        defer { page.documentController.discardAll(); model.cancelPendingReply(); store.removeAll(); files.remove() }
        let document = try files.document("valid")
        let composer = page.composerView
        composer.textView.text = "保留并重试"
        composer.textViewDidChange(composer.textView)
        let initialIDs = Set(messages(model).map(\.id))
        try await paste([dataProvider(.png, data: Data("not an image".utf8)), files.provider(url: document, type: .json)], into: composer)
        let ids = composer.orderedDocumentIDs
        try #require(ids.count == 2)
        try await waitUntil {
            page.documentController.drafts[ids[0]]?.status == .failed && page.documentController.drafts[ids[1]]?.status == .ready
        }
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(Set(messages(model).map(\.id)) == initialIDs)
        #expect(composer.orderedDocumentIDs == ids)
        #expect(composer.plainDraftText == "保留并重试")
        composer.removeDocument(ids[0], notify: true)
        let remaining = try #require(page.documentController.attachments(for: [ids[1]]))
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(messages(model).filter { !initialIDs.contains($0.id) }.map(\.content)
                == [.text("保留并重试")] + remaining.map { .attachment($0) })
        #expect(composer.orderedDocumentIDs.isEmpty)
        #expect(composer.plainDraftText.isEmpty)
    }

    @Test func invalidatedTokensAndSuspendedInputDoNotInsertAttachments() async throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer(text: "原文")
        var calls = 0
        composer.pasteAttachments = { _ in calls += 1 }
        let delegate = try #require(composer.textView.pasteDelegate)
        let item = PasteItemProbe(provider: dataProvider(.png))
        delegate.textPasteConfigurationSupporting?(composer.textView, transform: item)
        try await waitUntil { item.completionCount > 0 }
        let token = try #require(item.result)
        composer.pasteCoordinator.invalidate()
        let range = try #require(composer.textView.selectedTextRange)
        _ = delegate.textPasteConfigurationSupporting?(composer.textView, performPasteOf: token, to: range)
        #expect(calls == 0)
        #expect(composer.plainDraftText == "原文")
        composer.textView.isInputSuspended = true
        let suspended = PasteItemProbe(provider: dataProvider(.pdf))
        delegate.textPasteConfigurationSupporting?(composer.textView, transform: suspended)
        #expect(suspended.completionCount == 1)
        #expect(suspended.result?.length == 0)
        #expect(!suspended.usedDefault)
        #expect(calls == 0)
    }

    @Test func consecutivePastesInsertAtCaretAndReplacingOldCardCreatesNewIdentity() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let page = ChatViewController(viewModel: ChatViewModel(), audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        defer { page.documentController.discardAll(); page.viewModel.cancelPendingReply(); store.removeAll() }
        let composer = page.composerView
        composer.textView.text = "AB"
        composer.textView.selectedRange = NSRange(location: 1, length: 0)
        let link = NSItemProvider(object: "https://repeated.invalid" as NSString)
        try await paste([link], into: composer)
        let first = try #require(composer.orderedDocumentIDs.first)
        try await paste([NSItemProvider(object: " 中间 " as NSString), link], into: composer)
        let second = try #require(composer.orderedDocumentIDs.last)
        #expect(first != second)
        #expect(composer.draftSegments == [.text("A"), .attachment(first), .text(" 中间 "), .attachment(second), .text("B")])
        var firstRange: NSRange?
        composer.textView.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: composer.textView.textStorage.length)) { value, range, _ in
            if let attachment = value as? TextAttachment, attachment.draft.id == first { firstRange = range }
        }
        composer.textView.selectedRange = try #require(firstRange)
        try await paste([link], into: composer)
        let replacement = try #require(composer.orderedDocumentIDs.first)
        #expect(replacement != first && replacement != second)
        #expect(page.documentController.drafts[first] == nil)
        #expect(composer.draftSegments == [.text("A"), .attachment(replacement), .text(" 中间 "), .attachment(second), .text("B")])
        #expect(Set(page.documentController.drafts.keys) == Set([replacement, second]))
    }

    @available(iOS 26.0, *)
    private func makeComposer(text: String) -> ComposerView {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        composer.textView.text = text
        composer.textViewDidChange(composer.textView)
        return composer
    }

    /// 只模拟 UIKit 的 item 容器和默认无分隔拼接；分类与 token 生成全部由实际 delegate 执行。
    @available(iOS 26.0, *)
    private func paste(_ providers: [NSItemProvider], into composer: ComposerView) async throws {
        let textView = composer.textView
        let delegate = try #require(textView.pasteDelegate)
        // 先完成对象身份比较，避免 Swift 6 测试宏为 AnyObject 比较生成无效的泛型符合性。
        let usesPasteCoordinator = (delegate as AnyObject) === composer.pasteCoordinator
        #expect(usesPasteCoordinator)
        #expect(textView.pasteConfiguration != nil)
        let range = try #require(textView.selectedTextRange)
        let items = providers.map { PasteItemProbe(provider: $0) }
        for item in items { delegate.textPasteConfigurationSupporting?(textView, transform: item) }
        try await waitUntil { items.allSatisfy { $0.completionCount > 0 } }
        let combined = NSMutableAttributedString(string: "")
        for item in items {
            #expect(item.completionCount == 1)
            #expect(!item.usedDefault)
            combined.append(try #require(item.result))
        }
        let result = delegate.textPasteConfigurationSupporting?(textView, combineItemAttributedStrings: items.compactMap(\.result), for: range) ?? combined
        _ = delegate.textPasteConfigurationSupporting?(textView, performPasteOf: result, to: range)
        // UIKit 完成原生粘贴后，附件批次在下一次主队列提交，避免原生收尾重写草稿。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @available(iOS 26.0, *)
    private func dataProvider(_ type: UTType, data: Data = Data([1, 2, 3])) -> NSItemProvider {
        let provider = NSItemProvider()
        registerData(on: provider, type: type, data: data)
        return provider
    }

    @available(iOS 26.0, *)
    private func registerData(on provider: NSItemProvider, type: UTType, data: Data = Data([1, 2, 3])) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func messages(_ model: ChatViewModel) -> [MessagePresentation] {
        model.state.timeline.compactMap { item in
            guard case .message(let message) = item.content else { return nil }
            return message
        }
    }
}

/// 不实现分类、导入或生产 token；仅记录 UIKit UITextPasteItem 协议的实际返回结果。
@available(iOS 26.0, *)
@MainActor
private final class PasteItemProbe: NSObject, UITextPasteItem {
    let itemProvider: NSItemProvider
    let localObject: Any? = nil
    let defaultAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var result: NSAttributedString?
    private(set) var completionCount = 0
    private(set) var usedDefault = false

    init(provider: NSItemProvider) { itemProvider = provider; super.init() }
    func setResult(string: String) { finish(NSAttributedString(string: string, attributes: defaultAttributes)) }
    func setResult(attributedString: NSAttributedString) { finish(attributedString) }
    func setResult(attachment: NSTextAttachment) { finish(NSAttributedString(attachment: attachment)) }
    func setNoResult() { finish(NSAttributedString(string: "")) }
    func setDefaultResult() { usedDefault = true; finish(NSAttributedString(string: "")) }
    @available(iOS 26.0, *)
    private func finish(_ value: NSAttributedString) { completionCount += 1; result = value }
}

/// 使用真实 NSItemProvider 注册机制，只控制供应方何时完成，避免用 sleep 猜导入起点。
@available(iOS 26.0, *)
private final class PasteFileGate: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var completion: ((URL?, Bool, Error?) -> Void)?
    private var didStart = false
    private var didCancel = false
    private var didDeliver = false
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    var delivered: Bool { lock.withLock { didDeliver } }

    init(url: URL) { self.url = url }

    func provider(type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [self] callback in
            let progress = Progress(totalUnitCount: 1)
            progress.cancellationHandler = { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.didCancel = true }
            }
            lock.withLock { completion = callback; didStart = true }
            return progress
        }
        return provider
    }

    func succeed() { finish(error: nil) }
    func failIfPending() { finish(error: CocoaError(.userCancelled)) }
    @available(iOS 26.0, *)
    private func finish(error: Error?) {
        let callback = lock.withLock { let value = completion; completion = nil; return value }
        guard let callback else { return }
        callback(error == nil ? url : nil, false, error)
        lock.withLock { didDeliver = true }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class PasteFiles {
    private let store = PageAttachmentStore()
    func remove() { store.removeAll() }

    func document(_ name: String) throws -> URL {
        let url = store.makeFileURL(prefix: name, pathExtension: "json")
        try Data("{\"fixture\":\"\(name)\"}".utf8).write(to: url)
        return url
    }

    func image() throws -> URL {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let url = store.makeFileURL(prefix: "image", pathExtension: "png")
        try #require(image.pngData()).write(to: url)
        return url
    }

    func audio() throws -> URL {
        let url = store.makeFileURL(prefix: "audio", pathExtension: "wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8_000 { samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 8_000)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func video() async throws -> URL {
        let url = store.makeFileURL(prefix: "video", pathExtension: "mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        try #require(writer.canAdd(input))
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        memset(base, 0x7f, CVPixelBufferGetBytesPerRow(pixels) * 48)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            try await waitUntil { input.isReadyForMoreMediaData || writer.status == .failed }
            try #require(writer.status == .writing)
            try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    func provider(url: URL, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }
}

@available(iOS 26.0, *)
@MainActor
private func waitUntil(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for paste/import fixture", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}
