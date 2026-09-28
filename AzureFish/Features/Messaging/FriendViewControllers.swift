import AzureFishAPI
import AzureFishChat
import QuickLayoutKit
import UIKit

/// 精确账号查询与资料确认；提交失败保留输入和本次申请身份。
final class AddFriendViewController: AccountScreen {
    private let runtime: ChatRuntime
    private let account = UITextField()
    private var contact: ChatContact?
    private var operation = UUID()
    private var task: Task<Void, Never>?
    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.addFriend" }
    override func viewDidLoad() {
        super.viewDidLoad()
        account.borderStyle = .roundedRect
        account.autocapitalizationType = .none
        account.autocorrectionType = .no
        account.semanticContentAttribute = .forceLeftToRight
        account.accessibilityIdentifier = "chat.friend.account"
        account.addAction(
            UIAction { [weak self] _ in
                self?.contact = nil
                self?.operation = UUID()
            }, for: .editingChanged)
        content = [label("chat.live.addHelp"), account]
        actions = [button("chat.live.lookup", primary: true) { [weak self] in self?.lookup() }]
        setNeedsQuickLayout()
    }
    private func lookup() {
        guard task == nil, let api = runtime.api else { return }
        let name = account.text ?? ""
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                let user = try await api.lookup(account: name)
                guard user.id != runtime.userID else { throw APIClientError.invalidRequest }
                let contact = try await api.contact(peer: user.id)
                self.contact = contact
                let controller = FriendViewController(runtime: runtime, contact: contact)
                navigationController?.pushViewController(controller, animated: true)
            } catch { showMessage("chat.live.lookupFailed") }
        }
    }
    deinit { task?.cancel() }
}
/// 根据权威关系呈现申请、接受和删除动作，失败时不乐观修改好友列表。
final class FriendViewController: AccountScreen {
    private let runtime: ChatRuntime
    private var contact: ChatContact
    private var operationIDs: [String: UUID] = [:]
    private var busy = false
    init(runtime: ChatRuntime, contact: ChatContact) {
        self.runtime = runtime
        self.contact = contact
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.friendProfile" }
    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }
    private func render() {
        let name = UILabel()
        name.text = contact.peer.nickname
        name.font = .preferredFont(forTextStyle: .largeTitle)
        name.numberOfLines = 0
        name.adjustsFontForContentSizeCategory = true
        let image = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
        image.tintColor = .systemBlue
        image.contentMode = .scaleAspectFit
        content = [name, label("chat.live." + contact.state, secondary: true)]
        actions = []
        if contact.state == "friend" {
            actions.append(button("chat.live.sendMessage", primary: true) { [weak self] in self?.openChat() })
            actions.append(button("chat.live.deleteFriend", destructive: true) { [weak self] in self?.confirmDelete() })
        } else if contact.state == "pending" {
            if contact.requesterID == runtime.userID {
                actions.append(button("chat.live.cancelRequest") { [weak self] in self?.mutate(.cancel) })
            } else {
                actions.append(button("chat.live.accept", primary: true) { [weak self] in self?.mutate(.accept) })
                actions.append(button("chat.live.reject") { [weak self] in self?.mutate(.reject) })
            }
        } else {
            actions.append(button("chat.live.request", primary: true) { [weak self] in self?.mutate(.request) })
        }
        setNeedsQuickLayout()
    }
    private func confirmDelete() {
        let alert = UIAlertController(
            title: Localization.text("chat.live.deleteFriend"),
            message: contact.peer.nickname + "\n" + Localization.text("chat.live.deleteHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localization.text("chat.live.deleteFriend"), style: .destructive) { [weak self] _ in
                self?.mutate(.delete)
            })
        present(alert, animated: true)
    }
    private func mutate(_ action: ContactAction) {
        guard !busy, let api = runtime.api, let engine = runtime.engine else { return }
        busy = true
        let key = action.rawValue + ":" + String(contact.revision)
        let id = operationIDs[key] ?? UUID()
        operationIDs[key] = id
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let result = try await api.mutateContact(
                    peer: contact.peer.id, action: action, revision: contact.revision, operationID: id)
                guard runtime.engine === engine else { return }
                try await engine.store.save(result)
                guard runtime.engine === engine else { return }
                contact = result
                render()
                runtime.changed()
                runtime.refresh()
            } catch {
                if case APIClientError.service(let failure) = error, failure.code == .contactVersionConflict {
                    if let fresh = try? await api.contact(peer: contact.peer.id) {
                        contact = fresh
                        render()
                    }
                    showMessage("chat.live.changed")
                } else {
                    showMessage("chat.live.failed")
                }
            }
        }
    }
    private func openChat() {
        guard !busy, let api = runtime.api else { return }
        busy = true
        let id = operationIDs["resolve"] ?? UUID()
        operationIDs["resolve"] = id
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let conversation = try await api.resolve(peer: contact.peer.id, operationID: id)
                try await runtime.engine?.store.save(conversation)
                runtime.changed()
                navigationController?.pushViewController(
                    ConversationPageFactory.make(runtime: runtime, conversation: conversation), animated: true)
            } catch { showMessage("chat.live.failed") }
        }
    }
}
/// 好友选择器；群聊提交失败保留群名和选择，重试沿用操作身份。
final class FriendPickerViewController: LiveChatListController {
    private let group: Bool
    private var selection = Set<String>()
    private var operation = UUID()
    private var submittedTitle: String?
    var completed: ((ChatConversation) -> Void)?
    init(runtime: ChatRuntime, group: Bool) {
        self.group = group
        super.init(runtime: runtime)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { group ? "chat.live.newGroup" : "chat.live.newChat" }
    override func viewDidLoad() {
        super.viewDidLoad()
        selected = { [weak self] id in self?.choose(id) }
        if group {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: Localization.text("chat.live.next"),
                primaryAction: UIAction { [weak self] _ in self?.groupName() })
        }
    }
    override func reloadRows() {
        rows = runtime.contacts.filter {
            $0.state == "friend" && (query.isEmpty || $0.peer.nickname.localizedStandardContains(query))
        }.map {
            LiveChatRow(
                id: $0.peer.id, title: $0.peer.nickname,
                subtitle: selection.contains($0.peer.id) ? Localization.text("chat.live.selected") : "",
                symbol: selection.contains($0.peer.id) ? "checkmark.circle.fill" : "person.crop.circle.fill")
        }
    }
    private func choose(_ id: String) {
        if group {
            if selection.contains(id) { selection.remove(id) } else if selection.count < 99 { selection.insert(id) }
            operation = UUID()
            reloadRows()
        } else {
            submit(peer: id)
        }
    }
    private func groupName() {
        guard !selection.isEmpty else { return }
        let alert = UIAlertController(
            title: Localization.text("chat.live.groupName"),
            message: String(selection.count) + " · " + Localization.text("chat.live.selected"), preferredStyle: .alert)
        alert.addTextField {
            $0.text = self.submittedTitle
            $0.placeholder = Localization.text("chat.live.groupName")
        }
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: Localization.text("chat.live.create"), style: .default) { [weak self] _ in
                guard let self else { return }
                let title = alert.textFields?.first?.text ?? ""
                if submittedTitle != title {
                    operation = UUID()
                    submittedTitle = title
                }
                submit(peer: nil)
            })
        present(alert, animated: true)
    }
    private func submit(peer: String?) {
        guard let api = runtime.api else { return }
        let id = operation
        Task { [weak self] in
            guard let self else { return }
            do {
                let conversation: ChatConversation
                if let peer {
                    conversation = try await api.resolve(peer: peer, operationID: id)
                } else {
                    conversation = try await api.createGroup(
                        title: submittedTitle ?? "", members: selection.sorted(), operationID: id)
                }
                try await runtime.engine?.store.save(conversation)
                runtime.changed()
                navigationController?.popViewController(animated: false)
                completed?(conversation)
            } catch { showError(error) }
        }
    }
}
#if DEBUG
    @available(iOS 17.0, *)
    #Preview("添加好友") { AddFriendViewController(runtime: ChatRuntime(session: .configured())) }
#endif
