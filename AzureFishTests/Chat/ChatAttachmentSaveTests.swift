import Testing
import UIKit
import Photos
import QuickLayoutKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAttachmentSaveTests {
    @available(iOS 26.0, *)
    private final class Saver: AttachmentSaving {
        var received: [AzureFish.Attachment] = []
        var pending: CheckedContinuation<AttachmentSaveOutcome, Error>?
        func save(_ attachment: AzureFish.Attachment, from presenter: UIViewController) async throws -> AttachmentSaveOutcome {
            received.append(attachment)
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func finish(_ result: Result<AttachmentSaveOutcome, Error>) {
            let continuation = pending
            pending = nil
            continuation?.resume(with: result)
        }
    }

    @available(iOS 26.0, *)
    private func file(_ url: URL = URL(fileURLWithPath: "/tmp/audio.m4a")) -> AzureFish.Attachment {
        .file(.init(id: UUID(), fileURL: url, displayName: "Audio Message.m4a", typeIdentifier: "public.mpeg-4-audio", byteCount: 3))
    }

    @available(iOS 26.0, *)
    private func message(_ attachment: AzureFish.Attachment, id: Int = 1, direction: MessageDirection = .incoming) -> MessagePresentation {
        .init(id: id, direction: direction, attachment: attachment, deliveryText: nil)
    }

    @available(iOS 26.0, *)
    private func drain() async { try? await Task.sleep(nanoseconds: 40_000_000) }

    @Test func onlyIncomingMediaAndFilesAreSaveable() {
        guard #available(iOS 26.0, *) else { return }
        let audio = ConversationPreviewData.audioAttachment
        let media = ConversationPreviewData.pastedMediaDrafts[0].attachment
        let cases: [(AzureFish.Attachment, Bool)] = [
            (file(), true), (media, true), (.audio(audio), false),
            (.link(.init(url: URL(string: "https://example.com")!)), false),
            (.mediaGroup(.init(items: [])), false)
        ]
        for (attachment, expected) in cases {
            #expect(AttachmentSavePolicy.showsButton(for: message(attachment)) == expected)
            #expect(!AttachmentSavePolicy.showsButton(for: message(attachment, direction: .outgoing)))
        }
    }

    @Test func successIsDeduplicatedAndDeadlineSurvivesReconfiguration() async {
        guard #available(iOS 26.0, *) else { return }
        let saver = Saver()
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = AttachmentSaveCoordinator(saver: saver, clock: { now }, sleep: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        defer { coordinator.invalidate() }
        let item = file()
        let key = AttachmentSaveKey(messageID: 1, attachmentID: item.id)
        coordinator.save(message: message(item), from: UIViewController())
        coordinator.save(message: message(item), from: UIViewController())
        await drain()
        #expect(saver.received == [item])
        #expect(coordinator.state(for: key) == .saving)
        saver.finish(.success(.saved))
        await drain()
        #expect(coordinator.state(for: key) == .completed)
        now = now.addingTimeInterval(1.01)
        #expect(coordinator.state(for: key) == .hidden)
        coordinator.save(message: message(item), from: UIViewController())
        await drain()
        #expect(saver.received.count == 1)
    }

    @Test func cancelledAndFailedOperationsCanRetryWithoutFalseSuccess() async {
        guard #available(iOS 26.0, *) else { return }
        let saver = Saver()
        let coordinator = AttachmentSaveCoordinator(saver: saver)
        defer { coordinator.invalidate() }
        let item = file()
        let key = AttachmentSaveKey(messageID: 1, attachmentID: item.id)
        var failureCount = 0
        coordinator.failed = { _ in failureCount += 1 }
        coordinator.save(message: message(item), from: UIViewController())
        await drain()
        saver.finish(.success(.cancelled))
        await drain()
        #expect(coordinator.state(for: key) == .available)
        #expect(failureCount == 0)
        coordinator.save(message: message(item), from: UIViewController())
        await drain()
        saver.finish(.failure(AttachmentSaveError.photoPermissionDenied))
        await drain()
        #expect(coordinator.state(for: key) == .available)
        #expect(failureCount == 1)
        #expect(saver.received.count == 2)
    }

    @Test func leavingPageSuppressesLateSuccessAndError() async {
        guard #available(iOS 26.0, *) else { return }
        for result: Result<AttachmentSaveOutcome, Error> in [.success(.saved), .failure(AttachmentSaveError.invalidAttachment)] {
            let saver = Saver()
            let coordinator = AttachmentSaveCoordinator(saver: saver)
            var updates = 0
            var failures = 0
            coordinator.stateDidChange = { _, _ in updates += 1 }
            coordinator.failed = { _ in failures += 1 }
            coordinator.save(message: message(file()), from: UIViewController())
            await drain()
            coordinator.invalidate()
            saver.finish(result)
            await drain()
            #expect(updates == 1)
            #expect(failures == 0)
        }
    }

    @Test func mediaGroupIsOneSaveAndMessageIdentityIsIndependent() async {
        guard #available(iOS 26.0, *) else { return }
        let saver = Saver()
        let coordinator = AttachmentSaveCoordinator(saver: saver)
        defer { coordinator.invalidate() }
        let group = MediaGroupAttachment(items: ConversationPreviewData.pastedMediaDrafts.flatMap { $0.attachment.mediaGroup?.items ?? [] })
        let attachment = AzureFish.Attachment.mediaGroup(group)
        coordinator.save(message: message(attachment), from: UIViewController())
        await drain()
        #expect(saver.received == [attachment])
        #expect(coordinator.state(for: .init(messageID: 2, attachmentID: group.id)) == .available)
        saver.finish(.success(.saved))
        await drain()
    }

    @Test func snapshotPreservesOriginalsAndSurvivesSourceCleanup() throws {
        guard #available(iOS 26.0, *) else { return }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source.m4a")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: source)
        var snapshot: AttachmentSaveSnapshot? = try .init(file(source), parentDirectory: parent)
        let copy = try #require(snapshot?.files.first)
        let directory = try #require(snapshot?.directoryURL)
        #expect(copy.lastPathComponent == "Audio Message.m4a")
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: copy) == bytes)
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func mediaSnapshotUsesAllOriginalFilesAndCleansPartialFailure() throws {
        guard #available(iOS 26.0, *) else { return }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let sources = [parent.appendingPathComponent("a.gif"), parent.appendingPathComponent("b.mov")]
        for (index, source) in sources.enumerated() { try Data([UInt8(index)]).write(to: source) }
        let items = sources.enumerated().map { index, url in
            MediaItem(assetIdentifier: nil, originalFileURL: url,
                thumbnailFileURL: parent.appendingPathComponent("missing-thumbnail"), pixelSize: CGSize(width: 100, height: 100),
                kind: index == 0 ? .image : .video(duration: 2))
        }
        let attachment = AzureFish.Attachment.mediaGroup(.init(items: items))
        do {
            let snapshot = try AttachmentSaveSnapshot(attachment, parentDirectory: parent)
            #expect(snapshot.files.count == 2)
            for (index, copy) in snapshot.files.enumerated() { #expect(try Data(contentsOf: copy) == Data([UInt8(index)])) }
        }
        try FileManager.default.removeItem(at: sources[1])
        #expect(throws: (any Error).self) { try AttachmentSaveSnapshot(attachment, parentDirectory: parent) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["a.gif"])
    }

    @Test func documentPickerCopiesRatherThanMoves() throws {
        guard #available(iOS 26.0, *) else { return }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).pdf")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
        let result = try DocumentExportSession.makePicker([source]) { files, asCopy in
            #expect(files == [source])
            #expect(asCopy)
            return picker
        }
        #expect(result === picker)
        #expect(throws: AttachmentSaveError.invalidAttachment) {
            try DocumentExportSession.makePicker([source.appendingPathExtension("missing")])
        }
    }

    @Test func incomingFileButtonFitsAndHiddenStatePreservesLayout() {
        guard #available(iOS 26.0, *) else { return }
        let attachment = file()
        let cell = DocumentBubbleCell(frame: .zero)
        for width: CGFloat in [280, 320, 402] {
            for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
                cell.quickLayoutDirectionViews.forEach { $0.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight }
                func layout(_ state: AttachmentSaveState) -> (CGRect, CGRect) {
                    cell.configure(message(attachment), saveState: state)
                    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
                    attributes.size = CGSize(width: width, height: 52)
                    cell.frame = CGRect(origin: .zero, size: cell.preferredLayoutAttributesFitting(attributes).size)
                    cell.setNeedsLayout()
                    cell.layoutIfNeeded()
                    return (cell.card.convert(cell.card.bounds, to: cell), cell.saveButton.convert(cell.saveButton.bounds, to: cell))
                }
                let available = layout(.available)
                #expect(available.1.width == 44 && available.1.height == 44)
                #expect(abs(available.0.midY - available.1.midY) < 1)
                #expect(!available.0.intersects(available.1))
                #expect(available.1.minX >= 12 && available.1.maxX <= width - 12)
                let hidden = layout(.hidden)
                #expect(available.0 == hidden.0 && available.1 == hidden.1)
                #expect(!cell.saveButton.isEnabled && !cell.saveButton.isAccessibilityElement)
            }
        }
        cell.prepareForReuse()
        cell.configure(message(attachment), saveState: .available)
        #expect(cell.saveButton.isEnabled)
    }
}

@MainActor
extension ChatAttachmentSaveTests {
    @available(iOS 26.0, *)
    private var mediaStrings: MediaStrings {
        .init(photo: "Photos", itemsFormat: "%d items", image: "Image", animatedImage: "GIF",
              video: "Video", videoDurationFormat: "%@", importing: "Importing", remove: "Remove",
              play: "Play", openPreview: "Preview", close: "Close", firstItem: "First", lastItem: "Last", positionFormat: "%d of %d")
    }

    @Test func completionTimerHidesWithoutAnotherRender() async throws {
        guard #available(iOS 26.0, *) else { return }
        let saver = Saver()
        let coordinator = AttachmentSaveCoordinator(saver: saver)
        defer { coordinator.invalidate() }
        let item = file()
        var transitions: [AttachmentSaveState] = []
        coordinator.stateDidChange = { _, state in transitions.append(state) }
        coordinator.save(message: message(item), from: UIViewController())
        await drain()
        saver.finish(.success(.saved))
        await drain()
        #expect(transitions == [.saving, .completed])
        try await Task.sleep(nanoseconds: 1_150_000_000)
        #expect(transitions == [.saving, .completed, .hidden])
    }

    @Test func mediaLayoutExcludesHeaderAndKeepsFrontIndexAcrossSaveStates() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixtures = ConversationPreviewData.pastedMediaDrafts.flatMap { $0.attachment.mediaGroup?.items ?? [] }
        for count in [1, 2, 5] {
            let items = (0..<count).map { index in
                let item = fixtures[index % fixtures.count]
                return MediaItem(assetIdentifier: nil, originalFileURL: item.originalFileURL,
                    thumbnailFileURL: item.thumbnailFileURL, pixelSize: item.pixelSize, kind: item.kind)
            }
            let group = MediaGroupAttachment(items: items)
            for width: CGFloat in [280, 320, 402] {
                for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
                    let cell = MediaBubbleCell(frame: .zero)
                    cell.quickLayoutDirectionViews.forEach { $0.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight }
                    func layout(_ state: AttachmentSaveState) -> (CGRect, CGRect) {
                        cell.configure(message(.mediaGroup(group)), group: group, frontIndex: count - 1, strings: mediaStrings, saveState: state)
                        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
                        attributes.size = CGSize(width: width, height: 52)
                        cell.frame = CGRect(origin: .zero, size: cell.preferredLayoutAttributesFitting(attributes).size)
                        cell.setNeedsLayout()
                        cell.layoutIfNeeded()
                        cell.mediaView.layoutIfNeeded()
                        return (cell.mediaView.convert(cell.mediaView.bounds, to: cell), cell.saveButton.convert(cell.saveButton.bounds, to: cell))
                    }
                    let available = layout(.available)
                    #expect(abs(available.1.midY - (available.0.midY + (count > 1 ? 16 : 0))) < 1)
                    #expect(available.1.width == 44 && available.1.height == 44)
                    #expect(available.1.minX >= 12 && available.1.maxX <= width - 12)
                    #expect(!available.0.intersects(available.1))
                    if direction == .rightToLeft { #expect(available.1.maxX <= available.0.minX) }
                    else { #expect(available.1.minX >= available.0.maxX) }
                    let hidden = layout(.hidden)
                    #expect(available.0 == hidden.0 && available.1 == hidden.1)
                    #expect(cell.mediaView.frontMediaIndex == count - 1)
                }
            }
        }
    }

    @Test func saveButtonsRenderInRealWindowAtReferenceSize() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        root.view.addSubview(canvas)
        canvas.backgroundColor = .systemBackground
        let fixtures = ConversationPreviewData.pastedMediaDrafts.flatMap { $0.attachment.mediaGroup?.items ?? [] }
        for (style, direction) in [(UIUserInterfaceStyle.light, UIUserInterfaceLayoutDirection.leftToRight), (.dark, .rightToLeft)] {
            window.overrideUserInterfaceStyle = style
            canvas.subviews.forEach { $0.removeFromSuperview() }
            var y: CGFloat = 12
            for (index, items) in [[fixtures[0]], fixtures].enumerated() {
                let group = MediaGroupAttachment(items: items)
                let cell = MediaBubbleCell(frame: .zero)
                cell.quickLayoutDirectionViews.forEach { $0.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight }
                canvas.addSubview(cell)
                cell.configure(message(.mediaGroup(group), id: index), group: group, frontIndex: 0, strings: mediaStrings)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
                attributes.size = CGSize(width: 402, height: 52)
                cell.frame = CGRect(origin: CGPoint(x: 0, y: y), size: cell.preferredLayoutAttributesFitting(attributes).size)
                cell.setNeedsLayout(); cell.layoutIfNeeded()
                y += cell.bounds.height + 4
            }
            for ext in ["m4a", "pdf"] {
                let cell = DocumentBubbleCell(frame: .zero)
                cell.quickLayoutDirectionViews.forEach { $0.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight }
                if direction == .rightToLeft { cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
                canvas.addSubview(cell)
                let attachment = AzureFish.Attachment.file(.init(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/Attachment.\(ext)"), displayName: "Attachment.\(ext)", typeIdentifier: ext == "m4a" ? "public.mpeg-4-audio" : "com.adobe.pdf", byteCount: 12345))
                cell.configure(message(attachment))
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 2, section: 0))
                attributes.size = CGSize(width: 402, height: 52)
                cell.frame = CGRect(origin: CGPoint(x: 0, y: y), size: cell.preferredLayoutAttributesFitting(attributes).size)
                cell.setNeedsLayout(); cell.layoutIfNeeded()
                y += cell.bounds.height + 4
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { _ in canvas.drawHierarchy(in: canvas.bounds, afterScreenUpdates: true) }
            Attachment.record(image, named: "attachment-save-\(style.rawValue).png")
        }
    }
}

@MainActor
extension ChatAttachmentSaveTests {
    @Test func systemSaverWritesWholeGroupOnceAndKeepsCopiesDuringAuthorization() async throws {
        guard #available(iOS 26.0, *) else { return }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let urls = [parent.appendingPathComponent("image.gif"), parent.appendingPathComponent("video.mov")]
        for url in urls { try Data([7, 8, 9]).write(to: url) }
        let items = urls.enumerated().map { index, url in
            MediaItem(assetIdentifier: nil, originalFileURL: url, thumbnailFileURL: parent.appendingPathComponent("not-original"),
                pixelSize: CGSize(width: 100, height: 100), kind: index == 0 ? .image : .video(duration: 1))
        }
        var writes = 0
        var copiedURLs: [URL] = []
        let saver = SystemAttachmentSaver(authorizePhotos: {
            // 页面可以在等待系统授权时清理原附件，保存必须继续使用独立副本。
            for url in urls { try? FileManager.default.removeItem(at: url) }
            return .authorized
        }, writePhotos: { received, copies, _ in
            writes += 1
            copiedURLs = copies
            #expect(received == items)
            #expect(copies.count == 2)
            #expect(copies.map(\.pathExtension) == ["gif", "mov"])
            for copy in copies {
                let bytes = try Data(contentsOf: copy)
                #expect(bytes == Data([7, 8, 9]))
            }
        })
        let outcome = try await saver.save(.mediaGroup(.init(items: items)), from: UIViewController())
        #expect(outcome == .saved)
        #expect(writes == 1)
        #expect(copiedURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func deniedPhotoAccessDoesNotSubmitTransaction() async throws {
        guard #available(iOS 26.0, *) else { return }
        let attachment = ConversationPreviewData.pastedMediaDrafts[0].attachment
        for status in [PHAuthorizationStatus.denied, .restricted] {
            var writes = 0
            let saver = SystemAttachmentSaver(authorizePhotos: { status }, writePhotos: { _, _, _ in writes += 1 })
            do {
                _ = try await saver.save(attachment, from: UIViewController())
                Issue.record("Denied permission unexpectedly saved")
            } catch {
                #expect(error as? AttachmentSaveError == .photoPermissionDenied)
            }
            #expect(writes == 0)
        }
    }

    @Test func failedPhotoTransactionCleansCopiesAndPropagatesFailure() async throws {
        guard #available(iOS 26.0, *) else { return }
        var copies: [URL] = []
        let saver = SystemAttachmentSaver(authorizePhotos: { .authorized }, writePhotos: { _, urls, _ in
            copies = urls
            throw CocoaError(.fileWriteOutOfSpace)
        })
        do {
            _ = try await saver.save(ConversationPreviewData.pastedMediaDrafts[0].attachment, from: UIViewController())
            Issue.record("Failed transaction unexpectedly saved")
        } catch {
            #expect((error as NSError).code == CocoaError.fileWriteOutOfSpace.rawValue)
        }
        #expect(!copies.isEmpty)
        #expect(copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

@MainActor
extension ChatAttachmentSaveTests {
    @Test func exportDismissalWaitsForSystemSuccessCallback() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        root.loadViewIfNeeded()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        _ = try #require(root.view.window)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("export-order-\(UUID().uuidString).txt")
        try Data("Export callback order".utf8).write(to: source)
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKey()
            try? FileManager.default.removeItem(at: source)
        }
        var presentedPicker: UIDocumentPickerViewController?
        let session = DocumentExportSession(presentPicker: { picker, _ in presentedPicker = picker })
        var result: AttachmentSaveOutcome?
        var failure: Error?
        let task = Task {
            do { result = try await session.export([source], from: root) }
            catch { failure = error }
        }
        for _ in 0..<50 where presentedPicker == nil && failure == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if let failure { throw failure }
        let picker = try #require(presentedPicker)
        picker.viewDidDisappear(false)
        await drain()
        #expect(result == nil)
        // 系统允许先关闭选择器再交付导出成功；关闭本身不能判定为取消。
        session.documentPicker(picker, didPickDocumentsAt: [source])
        await task.value
        #expect(result == .saved)
        // 重复/迟到的取消回调不能再次恢复同一个 continuation。
        session.documentPickerWasCancelled(picker)
        #expect(result == .saved)
    }
}
