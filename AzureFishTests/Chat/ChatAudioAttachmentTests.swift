import AVFoundation
import PhotosUI
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatAudioAttachmentTests {
    @Test func cardReplacesSelectionAndSurvivesPhotoRemovalAndPlaybackUpdates() {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer(text: "你好\ncaption")
        composer.textView.selectedRange = NSRange(location: 1, length: 1)
        composer.insertDocument(fileDraft)
        let attachment = composer.textAttachments[fileDraft.id]
        #expect(composer.plainDraftText == "你\ncaption")
        #expect(composer.textView.selectedRange == NSRange(location: 4, length: 0))
        #expect(composer.textView.textLayoutManager != nil)
        composer.applyMediaDraft(importingDraft())
        composer.insertDocument(fileDraft)
        composer.applyMediaDraft(nil)
        composer.applyState(.audioPreview(attachment: audio, isPlaying: true, progress: 0.4))
        #expect(composer.textAttachments[fileDraft.id] === attachment)
        composer.applyState(.idle)
        #expect(composer.textAttachments[fileDraft.id] === attachment)
        #expect(composer.textView.text.filter { $0 == "\u{FFFC}" }.count == 1)
        #expect(composer.sendButton.isEnabled)
    }

    @Test func mixedDraftSendsOrderedIDsAndPreservesDraftOnRejection() {
        guard #available(iOS 26.0, *) else { return }
        for text in ["", " ", "\n", "caption"] {
            let composer = makeComposer(text: text)
            composer.textView.selectedRange = NSRange(location: 0, length: 0)
            composer.insertDocument(fileDraft)
            #expect(composer.plainDraftText == text)
            var actions: [ComposerAction] = []
            composer.actionRequested = { actions.append($0); return false }
            composer.sendButton.sendActions(for: .touchUpInside)
            #expect(actions == [.sendDocuments(composer.draftSegments)])
            #expect(composer.textAttachments.count == 1)
            composer.applyMediaDraft(importingDraft())
            composer.sendButton.sendActions(for: .touchUpInside)
            #expect(actions.count == 1)
        }
    }

    @Test func deletionRemovesOnlyAudioAndUndoCannotResurrectIt() {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer(text: "caption")
        composer.textView.selectedRange = NSRange(location: 0, length: 0)
        composer.insertDocument(fileDraft)
        let saved = NSAttributedString(attributedString: composer.textView.attributedText)
        composer.applyMediaDraft(importingDraft())
        var cancellations = 0
        composer.actionRequested = { action in
            if action == .removeDocument(fileDraft.id) { cancellations += 1; composer.applyState(.idle) }
            return true
        }
        // 模拟 UIKit 提交选区删除后的 textStorage，与删除键、剪切走相同协调入口。
        composer.textView.textStorage.deleteCharacters(in: NSRange(location: 0, length: 1))
        composer.textViewDidChange(composer.textView)
        #expect(composer.textAttachments[fileDraft.id] == nil)
        #expect(composer.plainDraftText == "caption")
        #expect(composer.textView.text == "caption")
        #expect(composer.mediaDraft != nil)
        #expect(cancellations == 1)
        composer.textView.attributedText = saved // 模拟系统撤销或剪贴板粘回失效引用。
        composer.textViewDidChange(composer.textView)
        #expect(composer.textView.text == "caption")
        #expect(cancellations == 1)
    }

    @Test func realEditorDeletionAndMarkedTextPreserveFocusAndLayout() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let composer = makeComposer(text: "")
        root.view.addSubview(composer)
        composer.frame.origin.y = 160
        composer.applyState(.idle)
        layout(composer)
        #expect(composer.textView.becomeFirstResponder())
        composer.insertDocument(fileDraft)
        composer.actionRequested = { action in
            if action == .removeDocument(fileDraft.id) { composer.applyState(.idle) }
            return true
        }
        layout(composer)
        #expect(composer.textView.isFirstResponder)
        for whitespace in [" ", "\n"] {
            composer.textView.insertText(whitespace)
            composer.textViewDidChange(composer.textView)
            #expect(composer.plainDraftText == whitespace)
            composer.textView.deleteBackward()
            composer.textViewDidChange(composer.textView)
            #expect(composer.plainDraftText.isEmpty)
        }
        composer.textView.setMarkedText("你好", selectedRange: NSRange(location: 2, length: 0))
        composer.textViewDidChange(composer.textView)
        #expect(composer.textView.markedTextRange != nil)
        composer.textView.unmarkText()
        composer.textViewDidChange(composer.textView)
        #expect(composer.plainDraftText == "你好")
        composer.textView.selectedRange = NSRange(location: 1, length: 0)
        composer.textView.deleteBackward()
        composer.textViewDidChange(composer.textView)
        layout(composer)
        #expect(composer.textAttachments[fileDraft.id] == nil)
        #expect(composer.textView.text == "你好")
        #expect(composer.textView.isFirstResponder)
        #expect(composer.intrinsicContentSize.height == 60)
        composer.textView.resignFirstResponder()
        composer.insertDocument(fileDraft)
        layout(composer)
        #expect(!composer.textView.isFirstResponder)
        for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            composer.applyLayoutDirection(direction)
            composer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            layout(composer)
            try await Task.sleep(nanoseconds: 100_000_000)
            let cards = descendants(composer).compactMap { $0 as? AttachmentCard }
            let card = try #require(cards.first)
            #expect(card.bounds.height >= 82)
            #expect(card.bounds.width > 100)
            let frame = card.convert(card.bounds, to: composer)
            #expect(frame.minX >= 0 && frame.maxX <= composer.bounds.width + 1)
            #expect(composer.intrinsicContentSize.height > 140)
        }
    }

    @Test func selectingMediaDuringRealRecordingCancelsFileAndTimer() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = AudioFixture()
        defer { fixture.cleanUp() }
        let page = fixture.page
        page.loadViewIfNeeded()
        fixture.audio.startRecording()
        try await waitForRecording(fixture.audio)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.store.directoryURL, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        page.photoController.stateDidChange?(nil)
        guard case .recording = fixture.audio.state else { Issue.record("Empty selection cancelled recording"); return }
        page.photoController.stateDidChange?(importingDraft())
        #expect(fixture.audio.state == .idle)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(page.composerView.mediaDraft != nil)
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(fixture.audio.state == .idle)
    }

    @Test func previewTransfersOwnershipAndSendsAsFileBeforeText() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = AudioFixture()
        defer { fixture.cleanUp() }
        let page = fixture.page
        page.loadViewIfNeeded()
        fixture.audio.startRecording()
        try await waitForRecording(fixture.audio)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        fixture.audio.stopRecording()
        let attachment = try #require(fixture.audio.previewAttachment?.audio)
        fixture.audio.togglePreviewPlayback()
        page.photoController.stateDidChange?(importingDraft())
        #expect(page.composerView.orderedDocumentIDs == [attachment.id])
        #expect(fixture.audio.state == .idle)
        #expect(fixture.audio.previewAttachment == nil)
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        // 原录音控制器的取消和播放回调不再拥有该文件。
        fixture.audio.cancelRecordingOrPreview()
        fixture.audio.togglePreviewPlayback()
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
        #expect(page.composerView.actionRequested?(.sendAttachmentDraft) == false)
        #expect(page.composerView.actionRequested?(.sendText("bypass")) == false)
        page.photoController.stateDidChange?(nil)
        page.composerView.textView.selectedRange = NSRange(location: page.composerView.textView.textStorage.length, length: 0)
        page.composerView.textView.insertText("caption")
        page.composerView.textViewDidChange(page.composerView.textView)
        page.composerView.sendButton.sendActions(for: .touchUpInside)
        #expect(page.composerView.textAttachments.isEmpty)
        #expect(page.documentController.drafts.isEmpty)
        let messages = page.viewModel.state.timeline.compactMap { item -> MessagePresentation? in
            if case .message(let message) = item.content { return message }; return nil
        }
        let fileMessage = try #require(messages.first { $0.id == 0 })
        guard case .attachment(.file(let file)) = fileMessage.content else { Issue.record("Must send a file, not a waveform recording"); return }
        #expect(file.id == attachment.id)
        #expect(file.fileURL.pathExtension == "m4a")
        #expect(messages.first { $0.id == 1 }?.text == "caption")
        #expect(FileManager.default.fileExists(atPath: attachment.fileURL.path))
    }

    @Test func previewTransferPrecedesPastedContentAtSelectedPosition() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = AudioFixture()
        defer { fixture.cleanUp() }
        let page = fixture.page
        page.loadViewIfNeeded()
        fixture.audio.startRecording()
        try await waitForRecording(fixture.audio)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        fixture.audio.stopRecording()
        let audio = try #require(fixture.audio.previewAttachment?.audio)
        let composer = page.composerView
        composer.textView.text = "AXZ"
        composer.textView.selectedRange = NSRange(location: 1, length: 1)
        page.documentController.insertPasted([.text("middle"), .link(URL(string: "https://after-audio.invalid")!)])
        let link = try #require(composer.orderedDocumentIDs.last)
        #expect(composer.draftSegments == [.text("A"), .attachment(audio.id), .text("middle"), .attachment(link), .text("Z")])
        #expect(fixture.audio.state == .idle)
        #expect(FileManager.default.isReadableFile(atPath: audio.fileURL.path))
        #expect(composer.textView.selectedRange == NSRange(location: composer.textView.textStorage.length - 1, length: 0))
    }

    @Test func deletingConvertedPreviewDiscardsItsFileAndPreservesPhotos() async throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = AudioFixture()
        defer { fixture.cleanUp() }
        fixture.page.loadViewIfNeeded()
        fixture.audio.startRecording()
        try await waitForRecording(fixture.audio)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        fixture.audio.stopRecording()
        let attachment = try #require(fixture.audio.previewAttachment?.audio)
        fixture.page.photoController.stateDidChange?(importingDraft())
        let composer = fixture.page.composerView
        composer.textView.textStorage.deleteCharacters(in: NSRange(location: 0, length: 1))
        composer.textViewDidChange(composer.textView)
        #expect(fixture.audio.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: attachment.fileURL.path))
        #expect(composer.mediaDraft != nil)
        #expect(composer.textAttachments.isEmpty)
    }

    @available(iOS 26.0, *)
    private var audio: AudioAttachment {
        .init(id: UUID(uuidString: "20602665-44B0-4C0E-9955-37AC10E951DD")!, fileURL: URL(fileURLWithPath: "/tmp/card.m4a"), duration: 2, waveform: [0.2, 0.4])
    }

    @available(iOS 26.0, *)
    private var fileDraft: DocumentDraft {
        .init(attachment: .file(.init(id: audio.id, fileURL: audio.fileURL,
            displayName: "Audio Message.m4a", typeIdentifier: "public.mpeg-4-audio", byteCount: 2048)))
    }

    @available(iOS 26.0, *)
    private func makeComposer(text: String) -> ComposerView {
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        composer.textView.text = text
        composer.textViewDidChange(composer.textView)
        return composer
    }

    @available(iOS 26.0, *)
    private func importingDraft() -> MediaDraftPresentation {
        .init(groupID: UUID(), items: [.init(id: UUID(), assetIdentifier: "test-photo", content: .importing)])
    }

    @available(iOS 26.0, *)
    private func layout(_ composer: ComposerView) {
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.setNeedsQuickLayout()
        composer.layoutIfNeeded()
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
    }

    @available(iOS 26.0, *)
    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @available(iOS 26.0, *)
    private func waitForRecording(_ audio: AudioController) async throws {
        for _ in 0..<100 {
            if case .recording = audio.state { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Recorder did not enter recording state")
        throw CancellationError()
    }
}

@available(iOS 26.0, *)
@MainActor
private final class AudioFixture {
    let store = PageAttachmentStore()
    let audio: AudioController
    let page: ChatViewController
    init() {
        audio = AudioController(
            audioSession: SystemAudioSessionController(), fileManager: .default,
            speechTranscriber: SilentTranscriber(), permissionProvider: GrantedPermissions(), attachmentStore: store
        )
        page = ChatViewController(viewModel: ChatViewModel(), audioController: audio)
    }
    func cleanUp() { page.documentController.discardAll(); audio.cancelRecordingOrPreview(); page.viewModel.cancelPendingReply(); store.removeAll() }
}

@available(iOS 26.0, *)
@MainActor
private final class GrantedPermissions: MediaPermissionProviding {
    func requestMicrophonePermission() async -> Bool { true }
    func requestSpeechPermission() async -> Bool { true }
}

@available(iOS 26.0, *)
@MainActor
private final class SilentTranscriber: SpeechTranscribing {
    func start(locale: Locale, result: @escaping @MainActor (String, Bool) -> Void, failure: @escaping @MainActor () -> Void) async throws {}
    func stop() {}
}
