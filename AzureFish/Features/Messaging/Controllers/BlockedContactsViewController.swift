import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class BlockedContactsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .blocked) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("黑名单") { AppNavigationController(rootViewController: BlockedContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
#endif
