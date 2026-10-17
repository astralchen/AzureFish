import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class ContactsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .contacts) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("通讯录") { AppNavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
@available(iOS 17.0, *)
#Preview("通讯录 · 字母索引") { AppNavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.indexedContacts))) }
@available(iOS 17.0, *)
#Preview("空通讯录") { AppNavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: []))) }
#endif

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("通讯录 · 原生列表") { ContactsViewController(runtime: ChatRuntime(session: .configured())) }
#endif
