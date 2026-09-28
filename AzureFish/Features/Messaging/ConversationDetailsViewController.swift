import AzureFishAPI
import AzureFishChat
import UIKit

/// 展示会话权限与群管理动作；变更失败保留当前页面并重新读取权威版本。
final class ConversationDetailsViewController: LiveChatListController {
    private var conversation: ChatConversation
    private var operations: [String: UUID] = [:]
    init(runtime: ChatRuntime, conversation: ChatConversation) {
        self.conversation = conversation
        super.init(runtime: runtime)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.details" }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.searchController = nil
        selected = { [weak self] id in self?.perform(id) }
    }
    override func reloadRows() {
        if let current = runtime.conversations.first(where: { $0.id == conversation.id }) { conversation = current }
        rows = [
            LiveChatRow(
                id: "title", title: runtime.title(conversation),
                subtitle: conversation.closed ? Localization.text("chat.live.closed") : "",
                symbol: conversation.kind == "group" ? "person.3" : "person.crop.circle")
        ]
        if conversation.kind == "group" {
            rows += conversation.members.filter(\.active).map { member in
                LiveChatRow(
                    id: "member:" + member.id,
                    title: runtime.contacts.first(where: { $0.peer.id == member.id })?.peer.nickname
                        ?? (member.id == runtime.userID ? runtime.session.profile?.nickname : nil)
                            ?? member.profile.nickname,
                    subtitle: member.id == conversation.ownerID ? Localization.text("chat.live.owner") : "",
                    symbol: "person.crop.circle")
            }
            if !conversation.closed {
                if conversation.ownerID == runtime.userID {
                    rows += [
                        LiveChatRow(id: "rename", title: Localization.text("chat.live.rename"), symbol: "pencil"),
                        LiveChatRow(
                            id: "add", title: Localization.text("chat.live.addMembers"), symbol: "person.badge.plus"),
                        LiveChatRow(id: "dissolve", title: Localization.text("chat.live.dissolve"), symbol: "trash"),
                    ]
                } else {
                    rows.append(
                        LiveChatRow(
                            id: "leave", title: Localization.text("chat.live.leave"),
                            symbol: "rectangle.portrait.and.arrow.right"))
                }
            }
        } else if let peer = conversation.members.first(where: { $0.id != runtime.userID }),
            let contact = runtime.contacts.first(where: { $0.peer.id == peer.id })
        {
            rows.append(
                LiveChatRow(
                    id: "friend",
                    title: Localization.text(
                        contact.state == "friend" ? "chat.live.friendProfile" : "chat.live.addFriend")))
        }
        rows.append(LiveChatRow(id: "clear", title: Localization.text("chat.live.clearLocal"), symbol: "trash"))
    }
    private func perform(_ id: String) {
        switch id {
        case "friend":
            if let peer = conversation.members.first(where: { $0.id != runtime.userID }),
                let contact = runtime.contacts.first(where: { $0.peer.id == peer.id })
            {
                navigationController?.pushViewController(
                    FriendViewController(runtime: runtime, contact: contact), animated: true)
            }
        case "clear":
            confirm(title: "chat.live.clearLocal", message: "chat.live.clearHelp") { [weak self] in
                guard let self else { return }
                Task {
                    do {
                        try await runtime.engine?.store.clear(conversation: conversation.id)
                        runtime.changed()
                    } catch { showError(error) }
                }
            }
        case "rename":
            let alert = UIAlertController(
                title: Localization.text("chat.live.rename"), message: nil, preferredStyle: .alert)
            alert.addTextField { $0.text = self.conversation.title }
            alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
            alert.addAction(
                UIAlertAction(title: Localization.text("account.design.save"), style: .default) { [weak self] _ in
                    self?.change(.rename, title: alert.textFields?.first?.text ?? "")
                })
            present(alert, animated: true)
        case "add": chooseFriend()
        case "leave", "dissolve":
            confirm(title: "chat.live." + id, message: "chat.live.groupCloseHelp") { [weak self] in
                self?.change(id == "leave" ? .leave : .dissolve)
            }
        default:
            if id.hasPrefix("member:"), conversation.ownerID == runtime.userID, !conversation.closed {
                member(String(id.dropFirst(7)))
            }
        }
    }
    private func member(_ id: String) {
        guard id != runtime.userID else { return }
        let sheet = UIAlertController(
            title: runtime.contacts.first(where: { $0.peer.id == id })?.peer.nickname
                ?? Localization.text("chat.live.groupMember"), message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.removeMember"), style: .destructive) { [weak self] _ in
                self?.confirm(title: "chat.live.removeMember", message: "chat.live.removeHelp") {
                    self?.change(.remove, member: id)
                }
            })
        sheet.addAction(
            UIAlertAction(title: Localization.text("chat.live.transferOwner"), style: .default) { [weak self] _ in
                self?.confirm(title: "chat.live.transferOwner", message: "chat.live.transferHelp") {
                    self?.change(.transfer, member: id)
                }
            })
        sheet.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        present(sheet, animated: true)
    }
    private func chooseFriend() {
        let chooser = LiveChatListController(runtime: runtime)
        chooser.title = Localization.text("chat.live.addMembers")
        chooser.rows = runtime.contacts.filter { contact in
            contact.state == "friend"
                && !conversation.members.contains(where: { $0.id == contact.peer.id && $0.active })
        }.map { LiveChatRow(id: $0.peer.id, title: $0.peer.nickname) }
        chooser.selected = { [weak self, weak chooser] id in
            chooser?.navigationController?.popViewController(animated: true)
            self?.change(.add, member: id)
        }
        navigationController?.pushViewController(chooser, animated: true)
    }
    private func change(_ action: GroupAction, title: String = "", member: String = "") {
        guard let api = runtime.api else { return }
        let key = "\(action.rawValue):\(conversation.revision):\(title):\(member)"
        let id = operations[key] ?? UUID()
        operations[key] = id
        Task {
            do {
                let result = try await api.updateGroup(
                    conversation.id, revision: conversation.revision, action: action, title: title, member: member,
                    operationID: id)
                conversation = result
                try await runtime.engine?.store.save(result)
                runtime.changed()
                reloadRows()
            } catch {
                if let current = try? await api.conversation(conversation.id) {
                    conversation = current
                    reloadRows()
                }
                showError(error)
            }
        }
    }
    private func confirm(title: String, message: String, action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: Localization.text(title), message: Localization.text(message), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text(title), style: .destructive) { _ in action() })
        present(alert, animated: true)
    }
}
#if DEBUG
    @available(iOS 17.0, *)
    #Preview("新的朋友") { FriendRequestsViewController(runtime: ChatRuntime(session: .configured())) }
#endif
