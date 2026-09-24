//
//  ChatViewController+Interaction.swift
//  Demo
//

import Combine
import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit
import QuickLook

/// 处理用户操作与组件事件。
@available(iOS 26.0, *)
extension ChatViewController {

    /// 连接输入栏动作、媒体状态、文档插入和消息交互到页面控制器。
    func configureInteractions() {
        composerView.actionRequested = { [weak self] action in
            guard let self, !isRestoringDraft, !hasCleanedUpChat else { return false }
            isHandlingDraftAction = true
            defer {
                isHandlingDraftAction = false
                switch action {
                // 正文由 Composer 在受理返回后清空，届时统一报告最终快照。
                case .sendText, .sendMediaDraft, .sendDocuments: break
                default: draftContentDidChange(immediately: true)
                }
            }
            return handleComposerAction(action)
        }
        conversationView.actionRequested = { [weak self] action in
            self?.handleMessageAction(action)
        }
        audioController.stateDidChange = { [weak self] state in
            guard let self else { return }
            let previous = composerView.composerState
            applyAudioComposerState(state)
            // 录音计时和同一预览的播放进度不改变草稿；听写只保存已经进入编辑器的文字。
            switch (previous, state) {
            case (.recording, .recording): break
            case (.audioPreview(let before, _, _), .audioPreview(let after, _, _)) where before == after: break
            case (_, .dictating): draftContentDidChange()
            default: draftContentDidChange(immediately: true)
            }
        }
        audioController.playbackDidChange = { [weak self] playback in
            self?.conversationView.updateAudioPlayback(playback)
        }
        audioController.failureDidOccur = { [weak self] failure in
            self?.presentMediaFailure(failure)
        }
        documentController.willRemoveDraft = { [weak self] id in
            guard let self, attachmentPreviewSource == .documentDraft(id) else { return }
            attachmentPreviewTask?.cancel()
            attachmentPreviewGeneration += 1
            (attachmentPreviewController as? AttachmentPreviewController)?.playback.stop()
            attachmentPreviewController?.dismiss(animated: false)
        }
        documentController.willInsert = { [weak self] in
            guard let self else { return }
            if let selection = documentMenuSelection {
                documentMenuSelection = nil
                if NSMaxRange(selection) <= composerView.textView.textStorage.length {
                    composerView.textView.selectedRange = selection
                }
            }
            prepareForDocumentSelection()
        }
        documentController.pickerCancelled = { [weak self] in self?.documentMenuSelection = nil }
        composerView.pasteAttachments = { [weak self] sources in self?.documentController.insertPasted(sources) }
        documentController.contentsInserted = { [weak self] contents in self?.composerView.insertContents(contents) }
        documentController.draftInserted = { [weak self] draft in
            self?.composerView.insertDocument(draft)
        }
        documentController.draftUpdated = { [weak self] draft in
            self?.composerView.updateDocument(draft)
            self?.draftContentDidChange(immediately: true)
        }
        photoController.stateDidChange = { [weak self] draft in
            guard let self else { return }
            if let draft, !draft.items.isEmpty {
                prepareForDocumentSelection()
            }
            composerView.applyMediaDraft(draft)
            draftContentDidChange(immediately: true)
        }
        photoController.failureDidOccur = { [weak self] in
            self?.presentMediaFailure(.mediaImportFailed)
        }
        photoController.pickerDidPresent = { [weak self] picker in
            self?.bottomObstructionCoordinator.trackPicker(picker)
        }
        photoController.pickerDidFinishPresenting = { [weak self] picker in
            self?.bottomObstructionCoordinator.finishPickerPresentation(picker)
        }
        photoController.pickerDidDismiss = { [weak self] in
            self?.bottomObstructionCoordinator.stopTrackingPicker()
        }
        composerView.heightDidChange = { [weak self] change in
            guard let self else { return }
            conversationView.prepareForViewportChange()
            setNeedsQuickLayout()
            let updates = { [self] in
                layoutChatContent()
            }
            switch change {
            case .immediate:
                updates()
            case .textInput:
                UIView.animate(withDuration: 0.22, delay: 0,
                               options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                               animations: updates)
            case .mediaDraft:
                UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 1,
                               initialSpringVelocity: 0,
                               options: [.beginFromCurrentState, .allowUserInteraction], animations: updates)
            }
        }
        composerView.applyState(audioController.state)
        composerView.applyMediaDraft(photoController.draft, animated: false)
        composerView.textInputDidBeginEditing = { [weak self] in
            guard let self, photoController.isPresented else { return }
            // 先保存交接起点再关闭面板，否则面板向下退出时输入栏也会先下落再随键盘升起。
            bottomObstructionCoordinator.beginKeyboardHandoff()
            photoController.dismissPicker(animated: true)
        }
    }

    /// 录音面板切换时统一动画化外观和页面布局；计时与波形更新沿用当前几何。
    func applyAudioComposerState(_ state: ComposerState) {
        let changesAudioPanel: Bool
        switch (composerView.composerState, state) {
        case (.recording, .recording), (.audioPreview, .audioPreview):
            changesAudioPanel = false
        case (_, .recording), (.recording, _), (_, .audioPreview), (.audioPreview, _):
            changesAudioPanel = true
        default:
            changesAudioPanel = false
        }
        guard composerView.composerState != state else { return }
        // 听写开始/结束及转写换行也属于展示事务；录音计量和播放进度不启动动画。
        if !changesAudioPanel {
            switch state {
            case .recording, .audioPreview:
                composerView.applyState(state)
                return
            default:
                break
            }
        }
        composerView.performPresentationUpdate(duration: changesAudioPanel ? 0.28 : 0.22) { [self] in
            composerView.applyState(state)
        }
    }

    /// 处理输入栏发出的统一用户动作。
    ///
    /// 附件发送先让 ViewModel 验证并追加消息，成功后才提交页面草稿。该顺序保证
    /// 文件失效或后续图片、视频验证失败时，预览仍然可以重试或取消。
    ///
    /// - Parameter action: 输入栏发出的值类型动作。
    /// - Returns: 动作已经被对应业务层接受时为 `true`。
    private func handleComposerAction(
        _ action: ComposerAction
    ) -> Bool {
        switch action {
        case .sendText(let text), .sendMediaDraft(let text):
            return sendComposerDraft(segments: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.text(text)])
        case .sendDocuments(let segments):
            return sendComposerDraft(segments: segments)
        case .removeDocument(let id):
            documentController.remove(id)
            return true
        case .openDocument(let id):
            guard let draft = documentController.drafts[id], draft.status == .ready else { return false }
            audioController.stopPlayback()
            openAttachmentPreview(.init(attachment: draft.attachment, source: .documentDraft(id)))
            return true
        case .insertLink(let url):
            return documentController.insertLink(url)

        case .openMediaDraftItem(let id):
            guard let draft = photoController.draft else { return false }
            let ready = draft.items.compactMap { item -> MediaItem? in
                guard case .ready(let media) = item.content else { return nil }; return media
            }
            guard let index = ready.firstIndex(where: { $0.id == id }) else { return false }
            openAttachmentPreview(.init(attachment: .mediaGroup(.init(id: draft.groupID, items: ready)), initialIndex: index, source: .photoDraft(draft.groupID)))
            return true
        case .removeMediaDraftItem(let id):
            photoController.removeItem(id: id)
            return true

        case .requestAttachment(let kind):
            switch kind {
            case .photo:
                audioController.stopPlayback()
                photoController.present(
                    from: self,
                    keyboardHeight: bottomObstructionCoordinator
                        .storedKeyboardContentHeight
                )
                return true
            case .file:
                audioController.stopPlayback()
                documentMenuSelection = composerView.textView.selectedRange
                documentController.presentPicker(from: presentedViewController ?? self)
                return true
            case .link:
                documentMenuSelection = composerView.textView.selectedRange
                presentLinkEntry()
                return true
            case .audio:
                guard composerView.validateAudioRecordingRequest() else {
                    return false
                }
                // 录音动作只启动音频流程；文本焦点由用户操作决定，不能在菜单
                // 关闭后异步抢回焦点，否则会再次唤起键盘并带动输入栏移动。
                audioController.startRecording()
                return true
            }

        case .stopAudioRecording:
            audioController.stopRecording()
            return true

        case .cancelAttachmentDraft:
            audioController.cancelRecordingOrPreview()
            return true

        case .sendAttachmentDraft:
            guard composerView.canSendAudioDraft, photoController.draft == nil, documentController.drafts.isEmpty else { return false }
            guard let attachment = audioController.previewAttachment,
                  viewModel.sendAttachment(attachment) else {
                return false
            }
            return audioController.commitPreviewAttachment(id: attachment.id)

        case .toggleAudioPreviewPlayback:
            audioController.togglePreviewPlayback()
            return true

        case .startDictation:
            audioController.startDictation(
                locale: Localization.localizationController
                    .currentLocale.locale
            )
            return true

        case .stopDictation, .manualEditDuringDictation:
            audioController.stopDictation()
            return true
        }
    }

    /// 选择项目才改变音频状态；打开或关闭面板不触发此方法。
    private func prepareForDocumentSelection() {
        switch audioController.state {
        case .recording:
            audioController.cancelRecordingOrPreview()
        case .audioPreview:
            if let audio = audioController.takePreviewForFileAttachment() {
                documentController.adoptRecording(audio)
            }
        case .preparingSpeech, .dictating: audioController.stopDictation()
        case .idle: break
        }
    }

    /// 解析并核对完整文档快照，照片面板在先，编辑器片段保持原位置。
    private func sendComposerDraft(segments: [DraftSegment]) -> Bool {
        let ids = segments.compactMap { segment -> UUID? in
            if case .attachment(let id) = segment { return id }; return nil
        }
        guard !composerView.isShowingRecordingUnavailableHint,
              composerView.mediaDraft?.canSend != false,
              segments == composerView.draftSegments,
              let documents = documentController.attachments(for: ids) else { return false }
        let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        var contents: [MessageContent] = []
        if let draft = photoController.draft {
            guard let media = draft.attachment else { return false }
            contents.append(.attachment(.mediaGroup(media)))
        }
        for segment in segments {
            switch segment {
            case .attachment(let id):
                guard let attachment = documentsByID[id] else { return false }
                contents.append(.attachment(attachment))
            case .richText(let text):
                contents.append(.richText(text))
            case .text(let text):
                if let url = PasteSource.webURL(in: text) {
                    contents.append(.attachment(.link(.init(url: url))))
                } else {
                    contents.append(.userText(text))
                }
            }
        }
        guard viewModel.sendContents(contents) else {
            presentMediaFailure(.mediaInvalid)
            return false
        }
        documentController.commit(ids)
        if photoController.draft != nil { _ = photoController.commitDraft() }
        // 发送只消费草稿；照片面板继续保留当前档位，便于连续选择并发送。
        return true
    }

    /// 展示网页地址输入框，并将有效 URL 交给文档草稿控制器。
    private func presentLinkEntry() {
        let alert = UIAlertController(title: Localization.text("imessage.attachment.link"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.cancel"), style: .cancel) { [weak self] _ in
            self?.documentMenuSelection = nil
        })
        let add = UIAlertAction(title: Localization.text("imessage.attachment.add"), style: .default) { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text,
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            _ = documentController.insertLink(url)
        }
        add.isEnabled = false
        alert.textFields?.first?.addAction(UIAction { [weak alert, weak add] _ in
            let value = alert?.textFields?.first?.text ?? ""
            add?.isEnabled = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)).map(LinkAttachment.accepts) ?? false
        }, for: .editingChanged)
        alert.addAction(add)
        (presentedViewController ?? self).present(alert, animated: true)
    }

    /// 把时间线消息操作路由到类型专属的页面协调器。
    ///
    /// - Parameter action: Cell 发出的值类型操作。
    private func handleMessageAction(_ action: MessageAction) {
        switch action {
        case .menu(let operation, let target):
            handleMenuAction(operation, target: target)
        case .retryMessage(let messageID):
            viewModel.retryMessage(id: messageID)
        case .saveAttachment(let messageID, let attachment):
            guard let message = viewModel.state.timeline.compactMap({ item -> MessagePresentation? in
                guard case .message(let message) = item.content else { return nil }
                return message
            }).first(where: { $0.id == messageID && $0.content == .attachment(attachment) }) else { return }
            attachmentSaveCoordinator.save(message: message, from: self)
        case .openDocument(let messageID, let attachment):
            openAttachmentPreview(.init(attachment: attachment, source: .message(messageID)))
        case .toggleAudioPlayback(let messageID, let attachment):
            audioController.toggleMessagePlayback(
                messageID: messageID,
                attachment: attachment
            )
        case .openMediaGroup(let messageID, let attachment, let index):
            openAttachmentPreview(.init(attachment: .mediaGroup(attachment), initialIndex: index, source: .message(messageID)))
        }
    }
}
