//
//  ComposerView+Rendering.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 更新界面内容与展示状态。
@available(iOS 26.0, *)
extension ComposerView {

    /// 应用输入栏显示的本地化字符串。
    ///
    /// - Parameter strings: 输入栏当前及后续状态所需的完整字符串集合。
    func configure(
        strings: ComposerStrings,
        mediaStrings: MediaStrings? = nil
    ) {
        self.strings = strings
        if let mediaStrings {
            self.mediaStrings = mediaStrings
        }
        recordingUnavailableLabel.text = strings.recordingRequiresEmptyDraft
        sendButton.accessibilityLabel = strings.send
        attachmentButton.accessibilityLabel = strings.addAttachment
        recordingStopButton.accessibilityLabel = strings.stopRecording
        audioCancelButton.accessibilityLabel = strings.cancelAudio
        audioSendButton.accessibilityLabel = strings.send
        updateAttachmentMenu()
        updateComposerState()
        mediaDraftStripView.configure(mediaDraft, strings: self.mediaStrings, animated: false)
        refreshTextAttachments()
        if case .audioPreview(_, let isPlaying, _) = composerState {
            audioPlayButton.accessibilityLabel = isPlaying
                ? strings.pauseAudio
                : strings.playAudio
        }
    }

    /// 应用照片选择器产生的有序媒体草稿。
    func applyMediaDraft(_ draft: MediaDraftPresentation?, animated: Bool = true) {
        let draft = draft?.items.isEmpty == false ? draft : nil
        let shouldAnimate = animated && window != nil && UIView.areAnimationsEnabled
            && !UIAccessibility.isReduceMotionEnabled
        let previousLayoutMode = layoutMode
        let previousContentHeight = resolvedContentHeight
        let isFirstVisibleDraft = !hasVisibleMediaDraft && draft?.hasVisibleItems == true
        // 先固定旧几何；业务状态立即提交，快照仅负责最后一张的视觉退场。
        superview?.layoutIfNeeded()
        if draft != mediaDraft {
            mediaDraftExitSnapshot?.removeFromSuperview()
            mediaDraftExitSnapshot = nil
        }
        if shouldAnimate, hasVisibleMediaDraft, draft?.hasVisibleItems != true, !mediaDraftStripView.isHidden,
           let host = superview, let snapshot = mediaDraftStripView.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = mediaDraftStripView.convert(mediaDraftStripView.bounds, to: host)
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            host.addSubview(snapshot)
            mediaDraftExitSnapshot = snapshot
        }
        mediaDraft = draft
        // 首张只随输入栏展开揭示，后续追加才使用 collection 的插入过渡。
        mediaDraftStripView.configure(draft, strings: mediaStrings,
                                      animated: shouldAnimate && !isFirstVisibleDraft)
        updateAttachmentMenu()
        updateComposerState()
        inputGlassView.setNeedsQuickLayout()
        setNeedsQuickLayout()
        let layoutChanged = previousLayoutMode != layoutMode
            || abs(previousContentHeight - resolvedContentHeight) > 0.5
        if layoutChanged {
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
            notifyHeightChange(shouldAnimate ? .mediaDraft : .immediate)
        }
        if let snapshot = mediaDraftExitSnapshot {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                snapshot.alpha = 0
                snapshot.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            } completion: { [weak self, weak snapshot] _ in
                snapshot?.removeFromSuperview()
                if self?.mediaDraftExitSnapshot === snapshot { self?.mediaDraftExitSnapshot = nil }
            }
        }
    }

    /// 渲染页面协调器生成的输入栏状态。
    ///
    /// - Parameter state: 当前音频录制、预览或语音转写状态。传入
    ///   ``ComposerState/idle`` 会恢复普通文本输入栏，但不会
    ///   修改其中的草稿。
    func applyState(_ state: ComposerState) {
        if state != .idle {
            dismissRecordingUnavailableHint()
        }
        let previousLayoutMode = layoutMode
        let previousContentHeight = resolvedContentHeight
        let previousState = composerState
        composerState = state
        switch state {
        case .idle:
            break
        case .preparingSpeech:
            dictationButton.isEnabled = false
        case .dictating(let text):
            dictationButton.isEnabled = true
            isApplyingTranscription = true
            if textAttachments.isEmpty { textView.text = text } else {
                let body = NSMutableAttributedString(string: "")
                for id in orderedDocumentIDs {
                    guard let attachment = textAttachments[id] else { continue }
                    body.append(NSAttributedString(attachment: attachment))
                    body.append(NSAttributedString(string: "\n", attributes: [TextAttachment.separatorKey: id.uuidString]))
                }
                body.append(NSAttributedString(string: text, attributes: textView.typingAttributes))
                textView.textStorage.setAttributedString(body)
            }
            isApplyingTranscription = false
            inputBinding.refresh()
            updateTextHeight()
            // 只报告已写入编辑器的听写结果，麦克风会话和录音计时不参与持久化。
            draftDidChange?()
        case .recording(let elapsed, let waveform):
            recordingWaveformView.samples = waveform
            recordingWaveformView.progress = 1
            let durationText = AudioBubbleView.durationText(elapsed)
            recordingDurationLabel.text = durationText
            recordingStopButton.accessibilityValue = durationText
        case .audioPreview(let attachment, let isPlaying, let progress):
            previewWaveformView.samples = attachment.waveform
            previewWaveformView.progress = progress
            let durationText = AudioBubbleView.durationText(
                attachment.duration, paddedMinutes: true
            )
            let elapsedText = AudioBubbleView.playbackTimeText(
                duration: attachment.duration, progress: progress, isPlaying: true, paddedMinutes: true
            )
            previewDurationLabel.text = AudioBubbleView.playbackTimeText(
                duration: attachment.duration, progress: progress, isPlaying: isPlaying, paddedMinutes: true
            )
            audioPlayButton.configuration?.image = UIImage(
                systemName: isPlaying ? "pause.fill" : "play.fill"
            )
            audioPlayButton.accessibilityLabel = isPlaying
                ? strings.pauseAudio
                : strings.playAudio
            audioPlayButton.accessibilityValue = "\(elapsedText) / \(durationText)"
        }

        let layoutModeChanged = previousLayoutMode != layoutMode
        let contentHeightChanged = abs(
            previousContentHeight - resolvedContentHeight
        ) > 0.5

        // 转写文本会改变占位符、可发送状态和文本高度；录音计量及播放进度
        // 只更新现有视图内容，保持媒体胶囊的几何与内边距不变。
        switch (previousState, state) {
        case (.recording, .recording), (.audioPreview, .audioPreview):
            if layoutModeChanged { updateComposerState() }
        default:
            // 内联附件会覆盖 layoutMode，但听写按钮与发送权限仍需随状态刷新。
            updateComposerState()
        }
        if layoutModeChanged {
            inputGlassView.setNeedsQuickLayout()
            setNeedsQuickLayout()
            superview?.setNeedsLayout()
        }
        if contentHeightChanged {
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
            notifyHeightChange(.immediate)
        }
    }

    /// 应用输入栏所有控件所使用的语义方向。
    func applyLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        let semanticAttribute = direction.appLayoutDirection
            .semanticContentAttribute
        semanticContentAttribute = semanticAttribute
        attachmentGlassView.semanticContentAttribute = semanticAttribute
        inputGlassView.semanticContentAttribute = semanticAttribute
        textActionContainer.semanticContentAttribute = semanticAttribute
        recordingGlassView.semanticContentAttribute = semanticAttribute
        previewGlassView.semanticContentAttribute = semanticAttribute
        audioCancelGlassView.semanticContentAttribute = semanticAttribute
        previewDurationContainer.semanticContentAttribute = semanticAttribute
        mediaDraftStripView.semanticContentAttribute = semanticAttribute
        mediaDraftSeparatorView.semanticContentAttribute = semanticAttribute
        textView.semanticContentAttribute = semanticAttribute
        inputBinding.refresh()
        placeholderLabel.semanticContentAttribute = semanticAttribute
        placeholderLabel.textAlignment = textView.textAlignment
        recordingUnavailableLabel.semanticContentAttribute = semanticAttribute
        refreshTextAttachments()
        setNeedsQuickLayout()
    }

    /// 根据当前输入与媒体状态同步控件显示、交互、辅助功能标签及波形。
    func updateComposerState() {
        let placeholder = mediaDraft == nil ? strings.placeholder : strings.mediaPlaceholder
        placeholderLabel.text = placeholder
        textView.accessibilityLabel = placeholder
        let showsTextInput: Bool
        switch composerState {
        case .idle, .preparingSpeech, .dictating:
            showsTextInput = true
        case .recording, .audioPreview:
            showsTextInput = !textAttachments.isEmpty
        }
        attachmentGlassView.alpha = showsTextInput ? 1 : 0
        inputGlassView.alpha = showsTextInput ? 1 : 0
        attachmentGlassView.isUserInteractionEnabled = showsTextInput
        // 不禁用文本编辑器的祖先视图，否则 UIKit 会结束当前编辑并收起键盘。
        // alpha 为 0 时容器不参与触摸命中；只隐藏外观即可保留用户已有的焦点。
        attachmentGlassView.accessibilityElementsHidden = !showsTextInput
        inputGlassView.accessibilityElementsHidden = !showsTextInput
        textView.alpha = isShowingRecordingUnavailableHint ? 0 : 1
        textView.isInputSuspended = isShowingRecordingUnavailableHint
        textView.accessibilityElementsHidden = isShowingRecordingUnavailableHint
        textView.isAccessibilityElement = !isShowingRecordingUnavailableHint
        let showsPlaceholder = !isShowingRecordingUnavailableHint && (textView.text ?? "").isEmpty
        // 先解除隐藏再修改 alpha，UIKit 才能捕获原来的透明起点。
        placeholderLabel.isHidden = !isAnimatingPresentation && !showsPlaceholder
        recordingUnavailableLabel.isHidden = !isAnimatingPresentation && !isShowingRecordingUnavailableHint
        placeholderLabel.alpha = showsPlaceholder ? 1 : 0
        recordingUnavailableLabel.alpha = isShowingRecordingUnavailableHint ? 1 : 0
        recordingUnavailableLabel.accessibilityElementsHidden = !isShowingRecordingUnavailableHint
        let canSend = !isShowingRecordingUnavailableHint && hasSendableContent
        // 导入进度只改变发送权限，不切换系统玻璃按钮的灰色/蓝色外观。
        // 隐藏期间也保留蓝色，首次出现与追加媒体都不会先闪过禁用色。
        sendButton.isEnabled = !isShowingRecordingUnavailableHint
        sendButton.isUserInteractionEnabled = canSend
        if canSend {
            sendButton.accessibilityTraits.remove(.notEnabled)
        } else {
            sendButton.accessibilityTraits.insert(.notEnabled)
        }
        sendButton.accessibilityHint = nil
        audioSendButton.isEnabled = canSendAudioDraft
        attachmentButton.isEnabled = !isShowingRecordingUnavailableHint
            && (composerState == .idle || !textAttachments.isEmpty)
        var dictationConfiguration = UIButton.Configuration.plain()
        dictationConfiguration.image = UIImage(systemName: "mic.fill")
        dictationConfiguration.contentInsets = .zero
        dictationConfiguration.cornerStyle = .capsule
        switch composerState {
        case .preparingSpeech:
            dictationButton.isEnabled = false
            dictationConfiguration.showsActivityIndicator = true
            dictationButton.tintColor = .label
            dictationButton.accessibilityLabel = strings.stopDictation
        case .dictating:
            dictationButton.isEnabled = true
            // 与录音停止按钮共用红色图标和浅红色胶囊背景。
            dictationConfiguration = recordingStopButton.configuration ?? dictationConfiguration
            dictationButton.tintColor = .systemRed
            dictationButton.accessibilityLabel = strings.stopDictation
        case .idle, .recording, .audioPreview:
            dictationButton.isEnabled = true
            dictationButton.tintColor = .label
            dictationButton.accessibilityLabel = strings.dictate
        }
        dictationButton.configuration = dictationConfiguration
        if isShowingRecordingUnavailableHint {
            dictationButton.isEnabled = false
        }
        textActionContainer.setNeedsQuickLayout()
        inputGlassView.setNeedsQuickLayout()
    }
}
