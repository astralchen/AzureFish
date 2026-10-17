import AzureFishAPI
import QuickLayoutKit
import UIKit

final class ContactSelectionViewController: ContactFormController {
    override var localizedTitleKey: String? { "chat.live.contacts" }
    override func viewDidLoad() { super.viewDidLoad(); reloadLocalizedContent() }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); fields = [text(Localization.text("contacts.select"), style: .title2)]; setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("选择联系人") { ContactSelectionViewController() }
#endif
