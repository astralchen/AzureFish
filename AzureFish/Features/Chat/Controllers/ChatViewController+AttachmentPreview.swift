//
//  ChatViewController+AttachmentPreview.swift
//  Demo
//

import Combine
import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit
import QuickLook

/// 协调附件浏览、来源定位与保存错误反馈。
@available(iOS 26.0, *)
extension ChatViewController {

    /// 根据附件保存错误显示本地化提示，并按需提供系统设置入口。
    func presentAttachmentSaveFailure(_ error: Error) {
        guard !hasCleanedUpChat, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let denied = (error as? AttachmentSaveError) == .photoPermissionDenied
        let alert = UIAlertController(title: Localization.text("imessage.error.title"),
            message: Localization.text(denied ? "imessage.save.permissionDenied" : "imessage.save.failed"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.ok"), style: .cancel))
        if denied {
            alert.addAction(UIAlertAction(title: Localization.text("imessage.action.settings"), style: .default) { [weak self] _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                self?.viewIfLoaded?.window?.windowScene?.open(url, options: nil, completionHandler: nil)
            })
        }
        present(alert, animated: true)
    }

    /// 分类文件后统一展示；保留编辑器内容、选区和底层照片面板。
    func openAttachmentPreview(_ request: AttachmentPreviewRequest) {
        guard attachmentPreviewController == nil else { return }
        audioController.stopPlayback()
        if case .link(let link) = request.attachment {
            viewIfLoaded?.window?.windowScene?.open(link.url, options: nil, completionHandler: nil)
            return
        }
        attachmentPreviewTask?.cancel()
        attachmentPreviewGeneration += 1
        let generation = attachmentPreviewGeneration
        attachmentPreviewSource = request.source
        let hadFocus = composerView.textView.isFirstResponder
        let selection = composerView.textView.selectedRange
        let document = NSAttributedString(attributedString: composerView.textView.attributedText)
        let work = Task.detached(priority: .userInitiated) { AttachmentPreviewItem.prepare(request.attachment) }
        attachmentPreviewTask = Task { [weak self] in
            var items = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard !Task.isCancelled, let self, generation == attachmentPreviewGeneration, !hasCleanedUpChat, !items.isEmpty else { return }
            switch request.source {
            case .documentDraft(let id): guard documentController.drafts[id]?.status == .ready else { return }
            case .photoDraft(let id): guard photoController.draft?.groupID == id else { return }
            case .message(let id):
                guard let message = viewModel.state.timeline.compactMap({ row -> MessagePresentation? in
                    guard case .message(let message) = row.content, message.id == id else { return nil }; return message
                }).first, case .attachment(let current) = message.content, current.id == request.attachment.id else { return }
                if items.indices.contains(request.initialIndex), case .mediaGroup(let group) = current,
                   !group.items.contains(where: { $0.id == items[request.initialIndex].id }) { return }
            }
            let restore: () -> Void = { [weak self] in
                guard let self else { return }
                attachmentPreviewController = nil
                attachmentPreviewSource = nil
                guard !hasCleanedUpChat else { return }
                if composerView.textView.attributedText.isEqual(to: document), NSMaxRange(selection) <= composerView.textView.textStorage.length {
                    composerView.textView.selectedRange = selection
                }
                if hadFocus { composerView.textView.becomeFirstResponder() }
            }
            let controller: UIViewController
            if items.count == 1, items[0].kind == .quickLook, QLPreviewController.canPreview(items[0].url as NSURL) {
                let quickLook = QuickLookPreviewController(url: items[0].url)
                quickLook.didClose = restore
                controller = quickLook
            } else {
                if items.count == 1, items[0].kind == .quickLook {
                    let item = items[0]
                    items[0] = .init(id: item.id, url: item.url, thumbnailURL: item.thumbnailURL, title: item.title, kind: .unavailable)
                }
                let preview = AttachmentPreviewController(items: items, initialIndex: request.initialIndex, playbackCoordinator: audioController.playbackCoordinator, imageLoader: mediaImageLoader)
                preview.didClose = restore
                preview.sourceResolver = { [weak self] index, synchronize in
                    guard let self else { return nil }
                    switch request.source {
                    case .message(let id):
                        return conversationView.previewSource(messageID: id, attachmentID: request.attachment.id, index: index, synchronize: synchronize)
                    case .documentDraft(let id):
                        return composerView.textAttachments[id]?.previewSourceView
                    case .photoDraft(let id):
                        guard photoController.draft?.groupID == id, items.indices.contains(index) else { return nil }
                        return composerView.mediaDraftStripView.previewSource(id: items[index].id)
                    }
                }
                controller = preview
            }
            controller.view.semanticContentAttribute = composerView.semanticContentAttribute
            attachmentPreviewController = controller
            var presenter: UIViewController = self
            while let presented = presenter.presentedViewController { presenter = presented }
            guard !presenter.isBeingDismissed else { restore(); return }
            if hadFocus { composerView.textView.resignFirstResponder() }
            presenter.present(controller, animated: true)
        }
    }
}
