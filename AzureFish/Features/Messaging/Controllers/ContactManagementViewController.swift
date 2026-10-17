import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 独立管理页承载单向删除和黑名单操作，不与发送消息争夺主要操作位置。
final class ContactManagementViewController: ContactFormController {
    private let runtime: ChatRuntime
    private var contact: ChatContact
    private var observation: UUID?
    init(runtime: ChatRuntime, contact: ChatContact) { self.runtime = runtime; self.contact = contact; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "contacts.manage" }
    override func viewDidLoad() {
        super.viewDidLoad()
        observation = runtime.observe { [weak self] in
            guard let self, let fresh = runtime.contacts.first(where: { $0.peer.id == contact.peer.id }), fresh.revision >= contact.revision else { return }
            contact = fresh; render()
        }
        render()
    }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); if isViewLoaded { render() } }
    private func render() {
        fields = [text(contact.displayName, style: .title2), text(Localization.text("contacts.blockHelp"), style: .footnote)]
        controls = []
        let blockAction: ContactAction = contact.isBlocked ? .unblock : .block
        if contact.allows(blockAction) {
            controls.append(action(contact.isBlocked ? "contacts.unblock" : "contacts.block") { [weak self] in self?.confirm(blockAction) })
        }
        if contact.allows(.delete) {
            controls.append(action("chat.live.deleteFriend", destructive: true) { [weak self] in self?.confirm(.delete) })
        }
        updateBusy(); setNeedsQuickLayout()
    }
    private func confirm(_ action: ContactAction) {
        guard !busy else { return }
        let key = action == .delete ? "chat.live.deleteFriend" : action == .block ? "contacts.block" : "contacts.unblock"
        let alert = UIAlertController(title: Localization.text(key), message: Localization.text(action == .delete ? "chat.live.deleteHelp" : "contacts.blockHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text(key), style: action == .unblock ? .default : .destructive) { [weak self] _ in self?.submit(action) })
        present(alert, animated: true)
    }
    private func submit(_ action: ContactAction) {
        guard !busy else { return }; busy = true
        Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do { contact = try await runtime.contactOperations.mutate(contact, action: action); statusKey = "contacts.saved"; render() }
            catch { if viewIfLoaded?.window != nil { report(error) } }
        }
    }
    deinit { if let observation { let runtime = runtime; Task { @MainActor in runtime.remove(observation) } } }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("好友管理") { ContactManagementViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact) }
#endif
