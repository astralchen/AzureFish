import AppLocalization
import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class ConversationMemberViewController: AccountScreen {
    private let runtime: ChatRuntime
    private let member: ChatMember
    private let conversationID: String?
    private var observation: UUID?
    var manage: ((GroupAction, @escaping (Bool) -> Void) -> Void)?
    private var busy = false
    init(runtime: ChatRuntime, member: ChatMember, conversationID: String? = nil) {
        self.runtime = runtime; self.member = member; self.conversationID = conversationID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.friendProfile" }
    override func viewDidLoad() {
        super.viewDidLoad()
        observation = runtime.observe { [weak self] in self?.reloadLocalizedContent() }
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        guard isViewLoaded else { return }
        let name = UILabel(); name.text = runtime.memberName(member); name.font = .preferredFont(forTextStyle: .title1); name.numberOfLines = 0; name.adjustsFontForContentSizeCategory = true
        let avatar = UIImageView(image: UIImage(systemName: "person.crop.square.fill"))
        avatar.tintColor = .secondaryLabel; avatar.contentMode = .scaleAspectFit
        content = [QuickLayoutView { avatar.resizable().frame(width: 64, height: 64) }, name]
        actions = [button("chat.live.friendProfile") { [weak self] in self?.openProfile() }]
        let conversation = runtime.conversations.first { $0.id == conversationID }
        if manage != nil, let conversation, !conversation.closed, conversation.ownerID == runtime.userID,
           conversation.members.contains(where: { $0.id == runtime.userID && $0.active }),
           conversation.members.contains(where: { $0.id == member.id && $0.active }) {
            actions.append(button("chat.live.removeMember", destructive: true) { [weak self] in self?.confirm(.remove, key: "removeMember", help: "removeHelp") })
            actions.append(button("chat.live.transferOwner") { [weak self] in self?.confirm(.transfer, key: "transferOwner", help: "transferHelp") })
        }
        actions.forEach { $0.isUserInteractionEnabled = !busy }
        setNeedsQuickLayout()
    }
    private func openProfile() {
        guard !busy else { return }
        if let contact = runtime.contacts.first(where: { $0.peer.id == member.id }) {
            navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: contact), animated: true)
            return
        }
        guard let engine = runtime.engine else { return }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let contact = try await runtime.refreshContact(peer: member.id)
                guard runtime.engine === engine, navigationController?.topViewController === self else { return }
                navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: contact), animated: true)
            } catch { showMessage("chat.live.failed") }
        }
    }
    private func confirm(_ action: GroupAction, key: String, help: String) {
        let alert = UIAlertController(title: Localization.text("chat.live." + key), message: Localization.text("chat.live." + help), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("chat.live." + key), style: .destructive) { [weak self] _ in
            guard let self, !busy else { return }
            busy = true
            actions.forEach { $0.isUserInteractionEnabled = false }
            manage?(action) { [weak self] success in
                guard let self else { return }
                busy = false
                actions.forEach { $0.isUserInteractionEnabled = true }
                if success { navigationController?.popViewController(animated: true) }
            }
        })
        present(alert, animated: true)
    }
    isolated deinit { if let observation { runtime.remove(observation) } }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("群成员资料") {
    ConversationMemberViewController(runtime: ConversationPreviewData.detailsRuntime(), member: ConversationPreviewData.detailsConversation().members[1])
}
#endif
