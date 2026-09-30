import AzureFishAPI
import AzureFishChat
import UIKit

/// 所有真实会话入口共用的系统版本路由；iOS 26 起复用完整原版聊天组件。
@MainActor
enum ConversationPageFactory {
    static func make(runtime: ChatRuntime, conversation: ChatConversation) -> UIViewController {
        if #available(iOS 26.0, *), let root = runtime.pageLeaseRoot,
           let drafts = runtime.originalDraftStore {
            let files = PageAttachmentStore(parentDirectory: root)
            let model = ChatViewModel()
            let controller = ChatViewController(viewModel: model,
                audioController: AudioController(attachmentStore: files), attachmentStore: files,
                conversationID: conversation.id, draftStore: drafts)
            controller.documentController.linkPreviewLoader = { [weak files] link in
                guard let files else { return link }
                return await AccountLinkPreview.load(link, files: files)
            }
            let session = LiveChatSession(runtime: runtime, conversation: conversation)
            controller.session = session
            drafts.legacyLoaders[files.directoryURL] = { [weak session, weak files] items in
                guard let session, let files else { throw CocoaError(.fileNoSuchFile) }
                var attachments: [Attachment] = []
                for item in items {
                    let kind = ["file", "audio"].contains(item.kind) ? item.kind : "media_group"
                    let batch = ChatUploadBatch(conversation: conversation.id, kind: kind, items: [item], deviceID: UUID())
                    attachments.append(try await session.resolve(batch, files: files))
                }
                return attachments
            }
            return controller
        }
        return LiveConversationViewController(runtime: runtime, conversation: conversation)
    }
}
