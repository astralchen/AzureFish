import AzureFishAPI
import AzureFishChat
import QuickLayoutKit
import UIKit

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
            $0.canSend && $0.matches(query)
        }.map {
            LiveChatRow(
                id: $0.peer.id, title: $0.displayName,
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
