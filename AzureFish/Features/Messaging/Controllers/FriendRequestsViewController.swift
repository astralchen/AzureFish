import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class FriendRequestsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .requests) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("新的朋友") { AppNavigationController(rootViewController: FriendRequestsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
#endif
