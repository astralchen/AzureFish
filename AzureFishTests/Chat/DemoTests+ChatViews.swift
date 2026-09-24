import AVFAudio
import CoreGraphics
import Testing
import UIKit
import AppLocalization
import QuickLayoutKit
@_spi(Testing) import QuickLayoutKitUIKit
@testable import AzureFish

extension DemoTests {

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerSingleLineButtonsCrossfadeAndRapidClearKeepsLatestState() async throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        let composer = controller.composerView
        let height = composer.bounds.height
        composer.textView.text = "a"
        composer.textViewDidChange(composer.textView)
        try await Task.sleep(nanoseconds: 50_000_000)
        let opacity = try #require(composer.sendButton.layer.presentation()).opacity
        #expect(opacity > 0 && opacity < 1)
        #expect(composer.bounds.height == height)
        composer.textView.text = ""
        composer.textViewDidChange(composer.textView)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(composer.sendButton.superview == nil)
        #expect(composer.dictationButton.superview != nil)
        #expect(!composer.placeholderLabel.isHidden)
        #expect(composer.placeholderLabel.alpha == 1)
        #expect(composer.bounds.height == height)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerDictationAndInterruptedHintShareContinuousGeometry() async throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        let composer = controller.composerView
        let original = composer.convert(composer.bounds, to: window)
        controller.applyAudioComposerState(.dictating(text: "one\ntwo\nthree\nfour"))
        try await waitForChatAnimation("听写输入栏应出现展开中间帧") {
            guard let layer = composer.layer.presentation() else { return false }
            return layer.bounds.height > original.height && layer.bounds.height < composer.bounds.height
        }
        let growing = try #require(composer.layer.presentation())
        #expect(growing.bounds.height > original.height)
        #expect(growing.bounds.height < composer.bounds.height)
        #expect(abs(growing.convert(growing.bounds, to: nil).maxY - original.maxY) < 1)
        controller.applyAudioComposerState(.idle)
        try await waitForChatAnimation("听写结束后输入栏应完成布局动画") {
            composer.layer.animationKeys()?.isEmpty != false
        }
        let expandedHeight = composer.bounds.height
        #expect(!composer.validateAudioRecordingRequest())
        try await waitForChatAnimation("录音不可用提示应出现收起中间帧") {
            guard let layer = composer.layer.presentation() else { return false }
            return layer.bounds.height < expandedHeight && layer.bounds.height > composer.bounds.height
        }
        let shrinking = try #require(composer.layer.presentation())
        let height = shrinking.bounds.height
        #expect(height < expandedHeight && height > composer.bounds.height)
        // 玻璃内容的 UIView.alpha 由 UIKit 合成，底层 layer.opacity 不代表可见透明度。
        #expect(composer.recordingUnavailableLabel.alpha == 1)
        #expect(!composer.recordingUnavailableLabel.isHidden)
        composer.dismissRecordingUnavailableHint()
        let continued = try #require(composer.layer.presentation()).bounds.height
        #expect(abs(continued - height) < 3)
        // 恢复尚未完成再次显示提示，旧 completion 不可隐藏新的提示。
        #expect(!composer.validateAudioRecordingRequest())
        try await waitForChatAnimation("再次显示提示后应完成当前动画") {
            composer.layer.animationKeys()?.isEmpty != false
        }
        #expect(!composer.recordingUnavailableLabel.isHidden)
        #expect(composer.recordingUnavailableLabel.alpha == 1)
        composer.dismissRecordingUnavailableHint()
        try await waitForChatAnimation("取消提示后应隐藏提示并完成高度恢复") {
            composer.recordingUnavailableLabel.isHidden && composer.layer.animationKeys()?.isEmpty != false
        }
        #expect(composer.recordingUnavailableLabel.isHidden)
        #expect(abs(composer.bounds.height - expandedHeight) < 0.5)
        #expect(composer.textView.text == "one\ntwo\nthree\nfour")
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerDocumentDeletionAnimatesAndBatchesHeightNotifications() async throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        let composer = controller.composerView
        let draft = DocumentDraft(attachment: .file(.init(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/transition.pdf"),
            displayName: "transition.pdf", typeIdentifier: "com.adobe.pdf", byteCount: 42)))
        let callback = composer.heightDidChange
        var notifications = 0
        composer.heightDidChange = { change in notifications += 1; callback?(change) }
        composer.insertDocument(draft)
        #expect(notifications == 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let expanded = composer.bounds.height
        notifications = 0
        composer.removeDocument(draft.id, notify: false)
        #expect(notifications == 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        let height = try #require(composer.layer.presentation()).bounds.height
        #expect(height < expanded && height > composer.bounds.height)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(composer.textAttachments.isEmpty)
        #expect(composer.sendButton.superview == nil)
        #expect(composer.dictationButton.superview != nil)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerAudioPanelAnimatesWithoutRestartingForMeterUpdates() async throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        let composer = controller.composerView
        let original = composer.convert(composer.bounds, to: window)
        controller.applyAudioComposerState(.recording(elapsed: 0, waveform: [0.1]))
        try await waitForChatAnimation("录音面板应同时出现高度和透明度中间帧") {
            guard let layer = composer.layer.presentation(),
                  let opacity = composer.recordingGlassView.layer.presentation()?.opacity else { return false }
            return layer.bounds.height > original.height && layer.bounds.height < composer.bounds.height
                && opacity > 0 && opacity < 1
        }
        let during = try #require(composer.layer.presentation())
        #expect(during.bounds.height > original.height)
        #expect(during.bounds.height < composer.bounds.height)
        #expect(abs(during.convert(during.bounds, to: nil).maxY - original.maxY) < 1)
        // 玻璃的 alpha 由 UIKit 合成；用公开状态确认退出，过渡画面另以录屏验证。
        #expect(composer.inputGlassView.alpha == 0)
        let recordOpacity = try #require(composer.recordingGlassView.layer.presentation()).opacity
        #expect(recordOpacity > 0 && recordOpacity < 1)
        try await waitForChatAnimation("录音面板应完成动画后再检查计量更新") {
            composer.layer.animationKeys()?.isEmpty != false
                && composer.inputGlassView.layer.animationKeys()?.isEmpty != false
        }
        controller.applyAudioComposerState(.recording(elapsed: 1, waveform: [0.3, 0.5]))
        #expect(composer.layer.animationKeys()?.isEmpty != false)
        #expect(composer.inputGlassView.layer.animationKeys()?.isEmpty != false)

        let attachment = AudioAttachment(fileURL: URL(fileURLWithPath: "/tmp/animation-preview.m4a"),
                                         duration: 2, waveform: [0.1, 0.4])
        controller.applyAudioComposerState(.audioPreview(attachment: attachment, isPlaying: false, progress: 0))
        try await waitForChatAnimation("音频预览应出现淡入中间帧") {
            guard let opacity = composer.previewGlassView.layer.presentation()?.opacity else { return false }
            return opacity > 0 && opacity < 1
        }
        let previewOpacity = try #require(composer.previewGlassView.layer.presentation()).opacity
        #expect(previewOpacity > 0 && previewOpacity < 1)
        controller.applyAudioComposerState(.idle)
        try await waitForChatAnimation("取消音频预览后应移除退出面板并完成高度恢复") {
            composer.recordingGlassView.superview == nil && composer.previewGlassView.superview == nil
                && composer.layer.animationKeys()?.isEmpty != false
        }
        #expect(composer.composerState == .idle)
        #expect(composer.inputGlassView.alpha == 1)
        #expect(composer.recordingGlassView.superview == nil)
        #expect(composer.previewGlassView.superview == nil)
        #expect(abs(composer.bounds.height - original.height) < 0.5)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerTextHeightAnimatesAndContinuesFromCurrentPosition() async throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        let window = try makeVisibleTestWindow(rootViewController: controller)
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 100_000_000)
        let composer = controller.composerView
        let original = composer.convert(composer.bounds, to: window)
        composer.textView.text = "One\nTwo\nThree\nFour"
        composer.textViewDidChange(composer.textView)
        let expandedHeight = composer.bounds.height
        #expect(expandedHeight > original.height + 30)
        try await Task.sleep(nanoseconds: 50_000_000)
        let expanding = try #require(composer.layer.presentation())
        let intermediate = expanding.convert(expanding.bounds, to: nil)
        #expect(intermediate.height > original.height)
        #expect(intermediate.height < expandedHeight)
        #expect(abs(intermediate.maxY - original.maxY) < 1)

        // 动画未完成即删除文字，新的收起动画应接续呈现位置。
        composer.textView.text = "One"
        composer.textViewDidChange(composer.textView)
        let continuing = try #require(composer.layer.presentation())
        #expect(abs(continuing.bounds.height - intermediate.height) < 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        let final = composer.convert(composer.bounds, to: window)
        #expect(abs(final.height - original.height) < 0.5)
        #expect(abs(final.maxY - original.maxY) < 0.5)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported))
    func composerTextHeightDoesNotAnimateRestorationOrUnchangedHeight() throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
        composer.layoutIfNeeded()
        var changes: [ComposerView.HeightChange] = []
        composer.heightDidChange = { changes.append($0) }
        composer.textView.text = "One\nTwo\nThree"
        composer.textViewDidChange(composer.textView)
        #expect(changes.count == 1)
        if case .immediate = changes[0] {} else { Issue.record("Offscreen restoration must not animate") }
        composer.textView.text = "Four\nFive\nSix"
        composer.textViewDidChange(composer.textView)
        #expect(changes.count == 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func composerGrowsToFiveLinesAndMirrorsDirection() {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60)
        )
        composer.configure(strings: ConversationPreviewData.composerStrings)
        composer.layoutIfNeeded()

        #expect(!composer.sendButton.isUserInteractionEnabled)
        #expect(!composer.placeholderLabel.isHidden)
        #expect(composer.attachmentButton.menu?.children.count == 4)
        #expect(
            composer.attachmentButton.cornerConfiguration == .capsule()
        )
        #expect(
            composer.attachmentButton.configuration?.cornerStyle == .capsule
        )
        #expect(composer.sendButton.cornerConfiguration == .capsule())
        #expect(composer.audioSendButton.cornerConfiguration == .capsule())
        #expect(
            composer.attachmentButton.menu?.children.map(\.title)
                == ["Photos", "Audio", "文件", "链接"]
        )
        let singleLineHeight = composer.intrinsicContentSize.height

        composer.textView.text = "Send this message"
        composer.textViewDidChange(composer.textView)
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        let sendFrame = composer.sendButton.convert(
            composer.sendButton.bounds,
            to: composer
        )
        #expect(abs(sendFrame.width - 38) < 0.5)
        #expect(abs(sendFrame.height - 28) < 0.5)
        #expect(abs(sendFrame.maxX - 368) < 0.5)
        #expect(abs(sendFrame.maxY - 44) < 0.5)
        #expect(sendFrame.width > sendFrame.height)
        let expandedHitPoint = composer.sendButton.convert(
            CGPoint(x: composer.sendButton.bounds.maxX + 2, y: composer.sendButton.bounds.midY),
            to: composer
        )
        #expect(composer.hitTest(expandedHitPoint, with: nil) === composer.sendButton)

        composer.textView.text = "one\ntwo\nthree\nfour\nfive\nsix\nseven"
        composer.textViewDidChange(composer.textView)
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()

        let maximumExpectedHeight = ceil(
            (composer.textView.font ?? .preferredFont(forTextStyle: .body))
                .lineHeight * 5
        ) + composer.textView.textContainerInset.top
            + composer.textView.textContainerInset.bottom + 16
        #expect(composer.intrinsicContentSize.height > singleLineHeight)
        #expect(
            composer.intrinsicContentSize.height <= maximumExpectedHeight + 1
        )
        #expect(composer.textView.isScrollEnabled)
        #expect(composer.sendButton.isEnabled)
        let multilineSendFrame = composer.sendButton.convert(composer.sendButton.bounds, to: composer.inputGlassView)
        #expect(abs(composer.inputGlassView.bounds.maxY - multilineSendFrame.maxY
            - ComposerView.Metrics.textSendBottomPadding) < 0.5)

        var sentText: String?
        composer.actionRequested = { action in
            guard case .sendText(let text) = action else { return false }
            sentText = text
            return true
        }
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(sentText == "one\ntwo\nthree\nfour\nfive\nsix\nseven")
        #expect(composer.textView.text.isEmpty)
        #expect(!composer.sendButton.isUserInteractionEnabled)
        #expect(!composer.placeholderLabel.isHidden)

        composer.applyLayoutDirection(.rightToLeft)
        #expect(composer.semanticContentAttribute == .forceRightToLeft)
        #expect(composer.textView.semanticContentAttribute == .forceRightToLeft)
        #expect(composer.textView.textAlignment == .right)
        composer.applyLayoutDirection(.leftToRight)
        #expect(composer.semanticContentAttribute == .forceLeftToRight)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func composerPreservesDraftAcrossAudioStates() {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 60)
        )
        composer.configure(strings: ConversationPreviewData.composerStrings)
        composer.textView.text = "draft text"
        composer.textViewDidChange(composer.textView)
        let attachment = AudioAttachment(
            fileURL: URL(fileURLWithPath: "/tmp/preview.m4a"),
            duration: 4,
            waveform: [0.2, 0.8, 0.4]
        )

        composer.applyState(
            .recording(elapsed: 2, waveform: [0.3, 0.7])
        )
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        let recordingWaveformFrame = composer.recordingWaveformView.convert(
            composer.recordingWaveformView.bounds,
            to: composer
        )
        let recordingStopFrame = composer.recordingStopButton.convert(
            composer.recordingStopButton.bounds,
            to: composer
        )
        #expect(composer.textView.text == "draft text")
        #expect(composer.textView.superview != nil)
        #expect(composer.intrinsicContentSize.height == 80)
        #expect(abs(recordingWaveformFrame.minX - 44) < 0.5)
        #expect(abs(recordingWaveformFrame.minY - 25) < 0.5)
        #expect(abs(recordingWaveformFrame.maxY - 55) < 0.5)
        #expect(composer.recordingWaveformView.minimumBarHeight == 2)
        #expect(composer.recordingWaveformView.maximumBarHeight == 12)
        #expect(composer.recordingWaveformView.barWidth == 2)
        #expect(composer.recordingWaveformView.barSpacing == 2)
        #expect(composer.recordingWaveformView.fadedLeadingFraction == 0.28)
        #expect(abs(recordingStopFrame.maxX - 360) < 0.5)
        #expect(abs(recordingStopFrame.minY - 22) < 0.5)
        #expect(abs(recordingStopFrame.height - 36) < 0.5)
        #expect(abs(recordingStopFrame.midY - 40) < 0.5)
        #expect(
            composer.recordingStopButton.point(
                inside: CGPoint(x: -3, y: 18),
                with: nil
            )
        )

        var repeatedHeightChangeCount = 0
        composer.heightDidChange = { _ in
            repeatedHeightChangeCount += 1
        }
        composer.applyState(
            .recording(elapsed: 59, waveform: [0.1, 0.5, 0.9])
        )
        composer.layoutIfNeeded()
        let repeatedWaveformFrame = composer.recordingWaveformView.convert(
            composer.recordingWaveformView.bounds,
            to: composer
        )
        let repeatedStopFrame = composer.recordingStopButton.convert(
            composer.recordingStopButton.bounds,
            to: composer
        )
        #expect(repeatedHeightChangeCount == 0)
        #expect(repeatedWaveformFrame == recordingWaveformFrame)
        #expect(repeatedStopFrame == recordingStopFrame)

        composer.applyState(
            .recording(elapsed: 60, waveform: [0.9, 0.5, 0.1])
        )
        composer.layoutIfNeeded()
        #expect(repeatedHeightChangeCount == 0)
        #expect(
            composer.recordingWaveformView.convert(
                composer.recordingWaveformView.bounds,
                to: composer
            ) == recordingWaveformFrame
        )
        #expect(
            composer.recordingStopButton.convert(
                composer.recordingStopButton.bounds,
                to: composer
            ) == recordingStopFrame
        )

        composer.applyState(
            .audioPreview(
                attachment: attachment,
                isPlaying: false,
                progress: 0
            )
        )
        composer.frame.size.height = composer.intrinsicContentSize.height
        composer.layoutIfNeeded()
        #expect(composer.textView.text == "draft text")
        #expect(composer.textView.superview != nil)
        #expect(composer.intrinsicContentSize.height == 80)
        let audioSendFrame = composer.audioSendButton.convert(
            composer.audioSendButton.bounds,
            to: composer
        )
        let audioPlayFrame = composer.audioPlayButton.convert(
            composer.audioPlayButton.bounds,
            to: composer
        )
        #expect(abs(audioSendFrame.width - 38) < 0.5)
        #expect(abs(audioSendFrame.height - 28) < 0.5)
        #expect(abs(audioSendFrame.maxX - 360) < 0.5)
        #expect(abs(audioSendFrame.minY - 26) < 0.5)
        #expect(audioSendFrame.width > audioSendFrame.height)
        #expect(abs(audioPlayFrame.minX - 82) < 0.5)
        #expect(abs(audioPlayFrame.minY - 22) < 0.5)
        #expect(abs(audioPlayFrame.maxY - 58) < 0.5)
        #expect(composer.previewWaveformView.minimumBarHeight == 2)
        #expect(composer.previewWaveformView.maximumBarHeight == 12)
        #expect(composer.previewWaveformView.barWidth == 2)
        #expect(composer.previewWaveformView.barSpacing == 2)
        #expect(composer.previewWaveformView.fadedLeadingFraction == 0)
        #expect(
            composer.audioSendButton.point(
                inside: CGPoint(x: 19, y: -7),
                with: nil
            )
        )

        composer.applyState(.idle)
        #expect(composer.textView.text == "draft text")
        #expect(composer.sendButton.isEnabled)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func rowsPinBubblesStatusAndTypingToSemanticEdges() throws {
        guard #available(iOS 26.0, *) else { return }
        let cellWidth: CGFloat = 390
        let horizontalInset: CGFloat = 12

        let incomingCell = TextBubbleCell(frame: .zero)
        incomingCell.configure(
            MessagePresentation(
                id: 1,
                direction: .incoming,
                text: "Short reply",
                deliveryText: nil
            )
        )
        layoutCell(incomingCell, width: cellWidth)
        let incomingFrame = incomingCell.bubbleView.convert(
            incomingCell.bubbleView.bounds,
            to: incomingCell
        )
        #expect(abs(incomingFrame.minX - horizontalInset) < 1)
        #expect(incomingFrame.width <= cellWidth * 0.75 + 1)

        let outgoingCell = TextBubbleCell(frame: .zero)
        outgoingCell.configure(
            MessagePresentation(
                id: 2,
                direction: .outgoing,
                text: "Short message",
                deliveryText: "Read"
            )
        )
        layoutCell(outgoingCell, width: cellWidth)
        let outgoingFrame = outgoingCell.bubbleView.convert(
            outgoingCell.bubbleView.bounds,
            to: outgoingCell
        )
        let deliveryFrame = outgoingCell.deliveryLabel.convert(
            outgoingCell.deliveryLabel.bounds,
            to: outgoingCell
        )
        #expect(
            abs(outgoingFrame.maxX - (cellWidth - horizontalInset)) < 1
        )
        #expect(abs(deliveryFrame.maxX - outgoingFrame.maxX) < 1)

        outgoingCell.semanticContentAttribute = .forceRightToLeft
        outgoingCell.setNeedsQuickLayout()
        outgoingCell.layoutIfNeeded()
        let rtlOutgoingFrame = outgoingCell.bubbleView.convert(
            outgoingCell.bubbleView.bounds,
            to: outgoingCell
        )
        #expect(abs(rtlOutgoingFrame.minX - horizontalInset) < 1)

        let typingCell = TypingCell(frame: .zero)
        typingCell.configure(accessibilityLabel: "Typing")
        layoutCell(typingCell, width: cellWidth)
        let typingFrame = typingCell.typingView.convert(
            typingCell.typingView.bounds,
            to: typingCell
        )
        #expect(abs(typingFrame.minX - horizontalInset) < 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func audioRowsPinToSemanticEdgesAndUpdatePlayback() {
        guard #available(iOS 26.0, *) else { return }
        let attachment = AudioAttachment(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!,
            fileURL: URL(fileURLWithPath: "/tmp/message.m4a"),
            duration: 8,
            waveform: [0.2, 0.7, 0.4, 0.9]
        )
        let cellWidth: CGFloat = 390
        let horizontalInset: CGFloat = 12
        let cell = AudioBubbleCell(frame: .zero)
        cell.configure(
            MessagePresentation(
                id: 7,
                direction: .outgoing,
                attachment: .audio(attachment),
                deliveryText: "Read"
            ),
            playback: .idle,
            playAccessibilityLabel: "Play",
            pauseAccessibilityLabel: "Pause"
        )
        layoutCell(cell, width: cellWidth)

        let ltrFrame = cell.bubbleView.convert(
            cell.bubbleView.bounds,
            to: cell
        )
        let ltrDeliveryFrame = cell.deliveryLabel.convert(
            cell.deliveryLabel.bounds,
            to: cell
        )
        #expect(abs(ltrFrame.maxX - (cellWidth - horizontalInset)) < 1)
        #expect(abs(ltrDeliveryFrame.maxX - ltrFrame.maxX) < 1)
        #expect(cell.bubbleView.waveformView.progress == 0)

        cell.updatePlayback(
            PlaybackState(
                messageID: 7,
                attachmentID: attachment.id,
                isPlaying: true,
                progress: 0.5
            ),
            playAccessibilityLabel: "Play",
            pauseAccessibilityLabel: "Pause"
        )
        #expect(cell.bubbleView.waveformView.progress == 0.5)
        #expect(cell.bubbleView.playButton.accessibilityLabel == "Pause")

        cell.semanticContentAttribute = .forceRightToLeft
        cell.setNeedsQuickLayout()
        cell.layoutIfNeeded()
        let rtlFrame = cell.bubbleView.convert(
            cell.bubbleView.bounds,
            to: cell
        )
        #expect(abs(rtlFrame.minX - horizontalInset) < 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func waveformDoesNotHighlightBeforePlaybackStarts() {
        guard #available(iOS 26.0, *) else { return }
        let sampleCount = 36

        for index in 0 ..< sampleCount {
            #expect(
                !WaveformView.isSamplePlayed(
                    at: index,
                    count: sampleCount,
                    progress: 0
                )
            )
        }
        #expect(
            !WaveformView.isSamplePlayed(
                at: 0,
                count: sampleCount,
                progress: 0.01
            )
        )
        #expect(
            WaveformView.isSamplePlayed(
                at: 0,
                count: sampleCount,
                progress: 0.02
            )
        )
        #expect(
            WaveformView.isSamplePlayed(
                at: sampleCount - 1,
                count: sampleCount,
                progress: 1
            )
        )
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func conversationAlignsOutgoingTextAndAudioTrailingEdges()
        async throws {
        guard #available(iOS 26.0, *) else { return }
        let attachment = AudioAttachment(
            id: UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!,
            fileURL: URL(fileURLWithPath: "/tmp/alignment.m4a"),
            duration: 8,
            waveform: Array(repeating: 0.4, count: 36)
        )
        let textMessage = MessagePresentation(
            id: 1,
            direction: .outgoing,
            text: "Aligned text",
            deliveryText: nil
        )
        let audioMessage = MessagePresentation(
            id: 2,
            direction: .outgoing,
            attachment: .audio(attachment),
            deliveryText: "Read"
        )
        let state = ChatViewModel.State(
            timeline: [
                TimelineItem(
                    id: .message(textMessage.id),
                    content: .message(textMessage)
                ),
                TimelineItem(
                    id: .message(audioMessage.id),
                    content: .message(audioMessage)
                ),
            ],
            isTyping: false
        )
        let controller = UIViewController()
        let conversation = ConversationView(frame: .zero)
        conversation.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(conversation)
        NSLayoutConstraint.activate([
            conversation.leadingAnchor.constraint(
                equalTo: controller.view.leadingAnchor
            ),
            conversation.trailingAnchor.constraint(
                equalTo: controller.view.trailingAnchor
            ),
            conversation.topAnchor.constraint(
                equalTo: controller.view.topAnchor
            ),
            conversation.bottomAnchor.constraint(
                equalTo: controller.view.bottomAnchor
            ),
        ])
        let window = try makeVisibleTestWindow(
            rootViewController: controller,
            size: CGSize(width: 390, height: 300)
        )
        defer { window.isHidden = true }

        conversation.render(state, reason: .initial)
        for _ in 0..<20 {
            if conversation.collectionView.numberOfSections > 0,
               conversation.collectionView.numberOfItems(inSection: 0) >= 2 {
                break
            }
            await Task.yield()
        }
        controller.view.layoutIfNeeded()
        conversation.collectionView.layoutIfNeeded()

        let textCell = try #require(
            conversation.collectionView.cellForItem(
                at: IndexPath(item: 0, section: 0)
            ) as? TextBubbleCell
        )
        let audioCell = try #require(
            conversation.collectionView.cellForItem(
                at: IndexPath(item: 1, section: 0)
            ) as? AudioBubbleCell
        )
        let textFrame = textCell.bubbleView.convert(
            textCell.bubbleView.bounds,
            to: conversation
        )
        let audioFrame = audioCell.bubbleView.convert(
            audioCell.bubbleView.bounds,
            to: conversation
        )
        let deliveryFrame = audioCell.deliveryLabel.convert(
            audioCell.deliveryLabel.bounds,
            to: conversation
        )
        #expect(abs(textFrame.maxX - audioFrame.maxX) < 1)
        #expect(abs(audioFrame.maxX - deliveryFrame.maxX) < 1)
        #expect(abs(audioFrame.maxX - 378) < 1)
    }

    @Test(.enabled(if: ChatTestAvailability.isSupported)) func contactTitleReportsCompleteNavigationSize() {
        guard #available(iOS 26.0, *) else { return }
        let titleView = ContactTitleView(frame: .zero)
        titleView.configure(subtitle: "iMessage")
        let size = titleView.intrinsicContentSize
        titleView.frame.size = size
        titleView.layoutIfNeeded()

        #expect(size.width > 80)
        #expect(size.height >= 30)
        #expect(titleView.avatarView.bounds.width == 30)
        #expect(titleView.nameLabel.bounds.width > 0)
        #expect(titleView.subtitleLabel.bounds.width > 0)
    }
}

@available(iOS 26.0, *)
@MainActor
private func layoutCell(
    _ cell: QuickLayoutCollectionViewCell,
    width: CGFloat
) {
    let attributes = UICollectionViewLayoutAttributes(
        forCellWith: IndexPath(item: 0, section: 0)
    )
    attributes.size = CGSize(width: width, height: 52)
    let fittedAttributes = cell.preferredLayoutAttributesFitting(attributes)
    cell.frame = CGRect(origin: .zero, size: fittedAttributes.size)
    cell.setNeedsLayout()
    cell.layoutIfNeeded()
}

/// 观察实际呈现状态与退场回调；固定 sleep 无法保证渲染事务已提交或完成。
/// 保留中间帧断言，超时仍失败，不把缺少动画或残留视图当作成功。
@MainActor
private func waitForChatAnimation(
    _ description: String,
    until condition: @MainActor () -> Bool
) async throws {
    CATransaction.flush()
    let deadline = CACurrentMediaTime() + 2
    while !condition(), CACurrentMediaTime() < deadline {
        try await Task.sleep(nanoseconds: 8_000_000)
    }
    try #require(condition(), Comment(rawValue: description))
}
