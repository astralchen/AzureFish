//
//  ComposerView+Interaction.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 处理用户操作与组件事件。
@available(iOS 26.0, *)
extension ComposerView {

    /// 使用当前本地化文字重建附件菜单，并在提示期间忽略菜单操作。
    func updateAttachmentMenu() {
        let photoAction = UIAction(
            title: mediaStrings.photo,
            image: UIImage(systemName: "photo.on.rectangle")
        ) { [weak self] _ in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(
                .requestAttachment(kind: .photo)
            )
        }
        let audioAction = UIAction(
            title: strings.audio,
            image: UIImage(systemName: "waveform")
        ) { [weak self] _ in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(
                .requestAttachment(kind: .audio)
            )
        }
        let fileAction = UIAction(title: strings.file, image: UIImage(systemName: "folder")) { [weak self] _ in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(.requestAttachment(kind: .file))
        }
        let linkAction = UIAction(title: strings.link, image: UIImage(systemName: "link")) { [weak self] _ in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(.requestAttachment(kind: .link))
        }
        attachmentButton.menu = UIMenu(children: [photoAction, audioAction, fileAction, linkAction])
    }

    /// 按草稿内容类型转发发送动作，并在上层受理后清空对应内容。
    @objc func sendButtonDidTap() {
        performPresentationUpdate(animated: false) { [self] in
            guard !isShowingRecordingUnavailableHint, hasSendableContent else { return }
            let text = plainDraftText
            let accepted: Bool
            let segments = draftSegments
            let hasFormatting = segments.contains { if case .richText = $0 { return true }; return false }
            if !textAttachments.isEmpty || hasFormatting {
                accepted = actionRequested?(.sendDocuments(segments)) == true
            } else if mediaDraft != nil {
                accepted = actionRequested?(.sendMediaDraft(text)) == true
            } else {
                accepted = actionRequested?(.sendText(text)) == true
            }
            guard accepted else { return }
            for attachment in textAttachments.values { attachment.open = nil; attachment.remove = nil }
            textAttachments.removeAll()
            textView.text = nil
            resetTypingAttributes(preservingFormatting: false)
            updateComposerState()
            // 发送后的空草稿与新消息同步布局，避免收起过程继续遮住刚发送的长文本。
            updateTextHeight(animated: false)
            // 仅在模型受理且输入栏清空后报告空快照；被拒绝的发送保留原草稿。
            draftDidChange?()
        }
    }

    /// 根据当前听写状态转发开始或停止听写动作。
    @objc func dictationButtonDidTap() {
        guard !isShowingRecordingUnavailableHint else { return }
        switch composerState {
        case .preparingSpeech, .dictating:
            _ = actionRequested?(.stopDictation)
        case .idle, .recording, .audioPreview:
            _ = actionRequested?(.startDictation)
        }
    }

    /// 转发停止录音动作。
    @objc func recordingStopButtonDidTap() {
        _ = actionRequested?(.stopAudioRecording)
    }

    /// 转发取消当前音频草稿的动作。
    @objc func audioCancelButtonDidTap() {
        _ = actionRequested?(.cancelAttachmentDraft)
    }

    /// 转发音频预览播放或暂停动作。
    @objc func audioPlayButtonDidTap() {
        _ = actionRequested?(.toggleAudioPreviewPlayback)
    }

    /// 在音频草稿可发送时转发发送动作。
    @objc func audioSendButtonDidTap() {
        guard canSendAudioDraft else { return }
        _ = actionRequested?(.sendAttachmentDraft)
    }
}
