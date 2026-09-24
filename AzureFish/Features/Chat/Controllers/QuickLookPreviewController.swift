import QuickLook
import UIKit

/// 仅用于系统兼容格式，保持 Quick Look 自带的文档交互和工具栏。
final class QuickLookPreviewController: QLPreviewController, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    private let fileURL: NSURL
    private var completed = false
    /// 系统完成或交互关闭后恢复来源界面。
    var didClose: (() -> Void)?
    init(url: URL) {
        fileURL = url as NSURL
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { fileURL }
    func previewControllerDidDismiss(_ controller: QLPreviewController) { complete() }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); if isBeingDismissed { complete() } }
    private func complete() { guard !completed else { return }; completed = true; didClose?() }
}

#if DEBUG
import SwiftUI
@available(iOS 17.0, *)
#Preview("文件预览 · 系统兼容") {
    QuickLookPreviewController(url: ConversationPreviewData.attachmentPreviewItems[0].url)
}
#endif
