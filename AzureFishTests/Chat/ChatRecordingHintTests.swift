import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatRecordingHintTests {
    @Test(arguments: [false, true])
    func linkAttachmentHintCollapsesAndRestoresDraft(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = HintSleeper()
        let composer = makeComposer(sleeper: sleeper)
        if rtl {
            composer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            composer.applyLayoutDirection(.rightToLeft)
        }
        layout(composer)
        let draft = DocumentDraft(
            attachment: .link(.init(url: URL(string: "https://apple.com")!))
        )
        composer.insertDocument(draft)
        layout(composer)
        let originalHeight = composer.intrinsicContentSize.height
        let originalText = NSAttributedString(attributedString: composer.textView.attributedText)
        let originalSelection = composer.textView.selectedRange
        let attachment = try #require(composer.textAttachments[draft.id])
        #expect(originalHeight > 60)

        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.hasPendingWait }
        layout(composer)
        let hintFrame = composer.recordingUnavailableLabel.convert(composer.recordingUnavailableLabel.bounds, to: composer)
        let addFrame = composer.attachmentButton.convert(composer.attachmentButton.bounds, to: composer)
        let sendFrame = composer.sendButton.convert(composer.sendButton.bounds, to: composer)
        #expect(composer.intrinsicContentSize.height == 60)
        #expect(composer.sizeThatFits(CGSize(width: 402, height: 1_000)).height == 60)
        #expect(abs(hintFrame.midY - addFrame.midY) < 0.5)
        #expect(abs(hintFrame.midY - sendFrame.midY) < 0.5)
        #expect(hintFrame.minY >= 8)
        #expect(hintFrame.maxY <= 52)
        #expect(!hintFrame.intersects(sendFrame))
        #expect(!composer.sendButton.isEnabled)
        #expect(composer.textAttachments[draft.id] === attachment)

        sleeper.resume()
        await waitUntil { !composer.isShowingRecordingUnavailableHint }
        layout(composer)
        #expect(composer.intrinsicContentSize.height == originalHeight)
        #expect(composer.textView.attributedText.isEqual(to: originalText))
        #expect(composer.textView.selectedRange == originalSelection)
        #expect(composer.textAttachments[draft.id] === attachment)
        #expect(composer.sendButton.isEnabled)
        #expect(composer.attachmentButton.isEnabled)
    }

    @Test func previewHintSurvivesInitialOffscreenMount() {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer()
        composer.textView.text = "preview draft"
        #expect(!composer.validateAudioRecordingRequest())
        let container = UIView()
        container.addSubview(composer)
        #expect(composer.isShowingRecordingUnavailableHint)
        composer.dismissRecordingUnavailableHint()
    }

    @Test func emptyDraftAllowsRecordingAndWhitespaceDoesNot() {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer()
        #expect(composer.validateAudioRecordingRequest())
        #expect(!composer.isShowingRecordingUnavailableHint)
        for text in [" ", "\n", "草稿"] {
            composer.textView.text = text
            composer.textViewDidChange(composer.textView)
            #expect(!composer.validateAudioRecordingRequest())
            #expect(composer.isShowingRecordingUnavailableHint)
            composer.dismissRecordingUnavailableHint()
            #expect(composer.textView.text == text)
        }
    }

    @Test func hintFreezesEditingAndRestoresMultilineDraftAfterTwoSeconds() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = HintSleeper()
        let composer = makeComposer(sleeper: sleeper)
        let draft = "one\ntwo\nthree\nfour\nfive\nsix\nseven"
        composer.textView.text = draft
        composer.textViewDidChange(composer.textView)
        layout(composer)
        composer.textView.selectedRange = NSRange(location: 2, length: 1)
        composer.textView.setContentOffset(CGPoint(x: 0, y: 12), animated: false)
        let offset = composer.textView.contentOffset
        let height = composer.intrinsicContentSize.height
        let parent = composer.textView.superview
        var actions: [ComposerAction] = []
        composer.actionRequested = { actions.append($0); return true }

        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.durations.count == 1 }
        #expect(sleeper.durations == [.seconds(2)])
        layout(composer)
        #expect(composer.intrinsicContentSize.height == 60)
        #expect(composer.textView.superview === parent)
        #expect(!composer.recordingUnavailableLabel.isHidden)
        #expect(composer.recordingUnavailableLabel.text == "若要录音，请清除输入栏。")
        #expect(!composer.attachmentButton.isEnabled)
        #expect(!composer.sendButton.isEnabled)
        #expect(!composer.textView(composer.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "x"))
        composer.textView.insertText("x")
        composer.textView.deleteBackward()
        composer.textView.setMarkedText("新", selectedRange: NSRange(location: 1, length: 0))
        composer.sendButton.sendActions(for: .touchUpInside)
        composer.dictationButton.sendActions(for: .touchUpInside)
        #expect(actions.isEmpty)
        #expect(composer.textView.text == draft)
        #expect(!composer.validateAudioRecordingRequest())
        #expect(sleeper.durations.count == 1)

        sleeper.resume()
        await waitUntil { !composer.isShowingRecordingUnavailableHint }
        layout(composer)
        #expect(composer.intrinsicContentSize.height == height)
        #expect(composer.textView.text == draft)
        #expect(composer.textView.selectedRange == NSRange(location: 2, length: 1))
        #expect(composer.textView.contentOffset == offset)
        #expect(composer.attachmentButton.isEnabled)
        #expect(composer.sendButton.isEnabled)
        #expect(!composer.textView.isInputSuspended)
        #expect(composer.recordingUnavailableLabel.isHidden)
    }

    @Test func mediaImportCanFinishWhileHintIsVisible() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = HintSleeper()
        let composer = makeComposer(sleeper: sleeper)
        let groupID = UUID()
        let items = (0..<2).map { index in
            MediaItem(
                assetIdentifier: "asset-\(index)",
                originalFileURL: URL(fileURLWithPath: "/tmp/hint-\(index).jpg"),
                thumbnailFileURL: URL(fileURLWithPath: "/tmp/hint-thumb-\(index).jpg"),
                pixelSize: CGSize(width: 100, height: 100),
                kind: index == 0 ? .image : .video(duration: 2)
            )
        }
        let importing = MediaDraftPresentation(
            groupID: groupID,
            items: items.map {
                .init(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .importing)
            }
        )
        let ready = MediaDraftPresentation(
            groupID: groupID,
            items: items.map {
                .init(id: $0.id, assetIdentifier: $0.assetIdentifier, content: .ready($0))
            }
        )
        composer.applyMediaDraft(importing)
        layout(composer)
        let height = composer.intrinsicContentSize.height
        let audioAction = try #require(composer.attachmentButton.menu?.children.last as? UIAction)
        #expect(!audioAction.attributes.contains(.disabled))
        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.durations.count == 1 }
        composer.applyMediaDraft(ready)
        layout(composer)
        #expect(composer.intrinsicContentSize.height == 60)
        #expect(!composer.sendButton.isEnabled)
        // 草稿容器持续挂载，以零高度裁剪隐藏，恢复时才有连续的旧几何。
        #expect(composer.mediaDraftStripView.bounds.height == 0)
        #expect(composer.mediaDraftStripView.clipsToBounds)
        var actions: [ComposerAction] = []
        composer.actionRequested = { actions.append($0); return false }
        composer.mediaDraftStripView.removeRequested?(items[0].id)
        #expect(actions.isEmpty)
        sleeper.resume()
        await waitUntil { !composer.isShowingRecordingUnavailableHint }
        layout(composer)
        #expect(composer.intrinsicContentSize.height == height)
        #expect(composer.mediaDraftStripView.superview != nil)
        #expect(composer.sendButton.isEnabled)
        #expect(composer.mediaDraft == ready)
        #expect(composer.mediaDraft?.attachment?.items == items)
        // 恢复后带文字再次触发同一规则，媒体和文本仍共存。
        composer.textView.text = "caption"
        composer.textViewDidChange(composer.textView)
        #expect(!composer.validateAudioRecordingRequest())
        composer.dismissRecordingUnavailableHint()
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(actions == [.sendMediaDraft("caption")])
    }

    @Test func hintFitsBothDirectionsAtAccessibilityTextSize() {
        guard #available(iOS 26.0, *) else { return }
        let composer = makeComposer()
        composer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        composer.textView.text = "多行\n草稿"
        composer.textViewDidChange(composer.textView)
        for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            composer.applyLayoutDirection(direction)
            #expect(!composer.validateAudioRecordingRequest())
            layout(composer)
            let label = composer.recordingUnavailableLabel
            #expect(label.font.pointSize <= 20)
            let hintFrame = label.convert(label.bounds, to: composer)
            let sendFrame = composer.sendButton.convert(composer.sendButton.bounds, to: composer)
            #expect(composer.intrinsicContentSize.height == 60)
            #expect(hintFrame.width > 100)
            #expect(hintFrame.minY >= 8)
            #expect(hintFrame.maxY <= 52)
            #expect(!hintFrame.intersects(sendFrame))
            #expect(abs(sendFrame.midY - hintFrame.midY) < 0.5)
            #expect(label.effectiveUserInterfaceLayoutDirection == direction)
            composer.dismissRecordingUnavailableHint()
            #expect(composer.textView.text == "多行\n草稿")
        }
    }

    @Test func staleCompletionCannotDismissNewHintOrReplaceAudioState() async {
        guard #available(iOS 26.0, *) else { return }
        let sleeper = HintSleeper()
        let composer = makeComposer(sleeper: sleeper)
        composer.textView.text = "draft"
        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.durations.count == 1 }
        composer.dismissRecordingUnavailableHint()
        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.durations.count == 2 }
        sleeper.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(composer.isShowingRecordingUnavailableHint)
        composer.applyState(.recording(elapsed: 1, waveform: [0.2]))
        sleeper.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(!composer.isShowingRecordingUnavailableHint)
        #expect(composer.intrinsicContentSize.height == 80)
        #expect(composer.textView.text == "draft")
    }

    @Test func hintPreservesFocusAndWindowRemovalCancelsIt() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        let sleeper = HintSleeper()
        let composer = makeComposer(sleeper: sleeper)
        controller.view.addSubview(composer)
        composer.textView.text = "原草稿"
        composer.textViewDidChange(composer.textView)
        layout(composer)
        for focused in [true, false] {
            if focused {
                #expect(composer.textView.becomeFirstResponder())
            } else {
                composer.textView.resignFirstResponder()
            }
            #expect(!composer.validateAudioRecordingRequest())
            await waitUntil { sleeper.hasPendingWait }
            layout(composer)
            #expect(composer.textView.isFirstResponder == focused)
            sleeper.resume()
            await waitUntil { !composer.isShowingRecordingUnavailableHint }
            layout(composer)
            #expect(composer.textView.isFirstResponder == focused)
        }
        #expect(!composer.validateAudioRecordingRequest())
        await waitUntil { sleeper.hasPendingWait }
        composer.removeFromSuperview()
        #expect(!composer.isShowingRecordingUnavailableHint)
        #expect(!composer.textView.isInputSuspended)
        sleeper.resume()
    }

    @available(iOS 26.0, *)
    private func makeComposer(sleeper: HintSleeper? = nil) -> ComposerView {
        let composer = ComposerView(frame: CGRect(x: 0, y: 100, width: 402, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        if let sleeper {
            composer.recordingHintSleeper = { try await sleeper.sleep($0) }
        }
        return composer
    }

    @available(iOS 26.0, *)
    private func layout(_ composer: ComposerView) {
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
    }

    @available(iOS 26.0, *)
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }
}

/// 故意允许已取消任务稍后完成，用于验证过期回调不会覆盖新状态。
@available(iOS 26.0, *)
@MainActor
private final class HintSleeper {
    private(set) var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, any Error>] = []
    var hasPendingWait: Bool { !continuations.isEmpty }

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func resume() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
