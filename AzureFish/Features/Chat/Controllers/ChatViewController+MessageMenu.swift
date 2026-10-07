import AppLocalization
import UIKit

@available(iOS 26.0, *)
extension ChatViewController {
    /// 所有入口（包括 VoiceOver）均重查内容身份和可执行能力。
    func handleMenuAction(_ operation: MessageMenuOperation, target: MessageMenuTarget) {
        guard !hasCleanedUpChat, let message = conversationView.message(for: target),
              MessageMenuPolicy.items(for: message, target: target, saveState: menuSaveCoordinator.state(for: target))
                .contains(where: { $0.operation == operation && $0.isEnabled }) else { return }
        if [.copy, .save, .share].contains(operation), let session,
           let attachment = target.attachment(in: message) {
            let id = UUID()
            attachmentActionTasks[id] = Task { [weak self] in
                defer { self?.attachmentActionTasks[id] = nil }
                do {
                    let resolved = try await session.resolveAttachment(attachment, messageID: target.messageID)
                    guard let self, !hasCleanedUpChat, conversationView.message(for: target) != nil else { return }
                    var local = MessagePresentation(id: message.id, direction: message.direction, attachment: resolved,
                        deliveryText: message.deliveryText, deliveryState: message.deliveryState)
                    local.canRevoke = message.canRevoke; local.canCancel = message.canCancel
                    local.canRetryMedia = message.canRetryMedia
                    performMenuOperation(operation, target: target, message: local)
                } catch is CancellationError {} catch { self?.presentAttachmentSaveFailure(error) }
            }
        } else { performMenuOperation(operation, target: target, message: message) }
    }
    private func performMenuOperation(_ operation: MessageMenuOperation, target: MessageMenuTarget, message: MessagePresentation) {
        switch operation {
        case .copy:
            Task { [weak self] in
                do {
                    let data = try await MessageClipboard.representations(for: message, target: target)
                    guard let self, !hasCleanedUpChat, conversationView.message(for: target) != nil else { return }
                    UIPasteboard.general.setItems([data])
                } catch {
                    if let self, !hasCleanedUpChat { presentAttachmentSaveFailure(error) }
                }
            }
        case .selectText: conversationView.selectMessageText(target)
        case .retry:
            if let session { session.retry(target.messageID) } else { viewModel.retryMessage(id: target.messageID) }
        case .revoke: session?.revoke(target.messageID)
        case .cancelSend: session?.delete(target.messageID)
        case .openLink:
            if case .link(let link) = target.attachment(in: message) {
                viewIfLoaded?.window?.windowScene?.open(link.url, options: nil, completionHandler: nil)
            }
        case .save: menuSaveCoordinator.save(target, message: message, from: self)
        case .share: shareMessage(message, target: target)
        case .delete: confirmMessageDeletion(message, target: target)
        }
    }

    /// 从消息辅助功能入口打开完整附件，链接交给当前窗口场景的系统浏览器处理。
    ///
    /// - Parameter target: 待打开的稳定内容身份；媒体组通过媒体项标识重新确定起始索引。
    ///
    /// 页面已清理、消息不存在或媒体项已移除时忽略请求，不衔接长按菜单的播放进度。
    func openMenuAttachment(_ target: MessageMenuTarget) {
        guard !hasCleanedUpChat, let message = conversationView.message(for: target),
              case .attachment(let attachment) = message.content else { return }
        if case .link(let link) = attachment {
            viewIfLoaded?.window?.windowScene?.open(link.url, options: nil, completionHandler: nil)
            return
        }
        let index: Int
        if let group = attachment.mediaPresentation {
            guard let selected = group.items.firstIndex(where: { $0.id == target.mediaItemID }) else { return }
            index = selected
        } else { index = 0 }
        openAttachmentPreview(.init(attachment: attachment, initialIndex: index,
                                    source: .message(target.messageID)))
    }

    private func shareMessage(_ message: MessagePresentation, target: MessageMenuTarget) {
        guard presentedViewController == nil, view.window != nil else { return }
        do {
            let items: [Any]
            let snapshot: AttachmentSaveSnapshot?
            switch message.content {
            case .text, .richText:
                items = [message.text]
                snapshot = nil
            case .attachment:
                guard let attachment = target.attachment(in: message) else { return }
                if case .link(let link) = attachment {
                    items = [link.url]
                    snapshot = nil
                } else {
                    let resources = try AttachmentSaveSnapshot(attachment, parentDirectory: session == nil ? FileManager.default.temporaryDirectory : attachmentStore.directoryURL.appendingPathComponent("exports/" + attachment.id.uuidString))
                    items = resources.files + resources.pairedVideos.compactMap { $0 }
                    snapshot = resources
                }
            }
            let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
            sheet.completionWithItemsHandler = { [weak self, snapshot] _, _, _, error in
                withExtendedLifetime(snapshot) {}
                if let error, let self, !hasCleanedUpChat { presentAttachmentSaveFailure(error) }
            }
            let source = conversationView.menuSourceView(for: target) ?? view!
            sheet.popoverPresentationController?.sourceView = source
            sheet.popoverPresentationController?.sourceRect = source.bounds
            present(sheet, animated: true)
        } catch { presentAttachmentSaveFailure(error) }
    }

    func confirmSystemNoticeDeletion(_ id: Int) {
        guard presentedViewController == nil, view.window != nil,
              viewModel.messages.contains(where: { $0.id == id && $0.systemNotice != nil }) else { return }
        let alert = UIAlertController(title: Localization.text("imessage.menu.deleteTitle"),
            message: Localization.text("imessage.menu.deleteDetail"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.localDelete"), style: .destructive) { [weak self] _ in
            guard let self, viewModel.messages.contains(where: { $0.id == id && $0.systemNotice != nil }) else { return }
            session?.delete(id)
        })
        present(alert, animated: true)
    }

    private func confirmMessageDeletion(_ message: MessagePresentation, target: MessageMenuTarget) {
        guard presentedViewController == nil, view.window != nil else { return }
        let multiple = (message.mediaGroup?.items.count ?? 0) > 1
        let alert = UIAlertController(title: Localization.text("imessage.menu.deleteTitle"),
                                      message: Localization.text(multiple ? "imessage.menu.deleteGroupDetail" : "imessage.menu.deleteDetail"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("imessage.menu.delete"), style: .destructive) { [weak self] _ in
            self?.deleteMenuMessage(target)
        })
        present(alert, animated: true)
    }

    /// 系统播放与消息状态在同一个主线程事务中退出，迟到转写通过消息身份过滤。
    func deleteMenuMessage(_ target: MessageMenuTarget) {
        guard conversationView.message(for: target) != nil else { return }
        if audioController.playbackState.messageID == target.messageID { audioController.stopPlayback() }
        conversationView.endMessageSelection()
        if let session { session.delete(target.messageID) } else { viewModel.deleteMessage(id: target.messageID) }
    }
}
