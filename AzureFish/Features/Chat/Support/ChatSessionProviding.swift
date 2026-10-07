import UIKit

/// 为原版会话页面提供真实数据操作；本地演示继续使用独立的 ChatViewModel 生命周期。
@MainActor
@available(iOS 26.0, *)
protocol ChatSessionProviding: AnyObject {
    func start(in controller: ChatViewController)
    func didAppear()
    func stop()
    func resolveAttachment(_ attachment: Attachment, messageID: Int) async throws -> Attachment
    func refresh()
    func loadHistory()
    /// 先将消息写入本地发送队列，再启动网络发送。
    ///
    /// `completion(true)` 表示本地事务已提交，可以消费草稿，不代表服务端已确认。
    /// 落库失败返回 `false`，调用方保留草稿。
    func send(_ contents: [MessageContent], completion: @escaping (Bool) -> Void)
    func retry(_ messageID: Int)
    func delete(_ messageID: Int)
    func revoke(_ messageID: Int)
    func reedit(_ messageID: Int)
    func viewportChanged()
    func didTranscribe(_ text: String, messageID: Int, attachmentID: UUID)
}

@available(iOS 26.0, *)
extension ChatSessionProviding {
    func didAppear() {}
    func resolveAttachment(_ attachment: Attachment, messageID: Int) async throws -> Attachment {
        if case .remote = attachment { throw AttachmentSaveError.invalidAttachment }
        return attachment
    }
}
