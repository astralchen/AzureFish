import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 完整账号查询；新输入、离开页面和账号变化使旧查询失效。
final class AddFriendViewController: ContactFormController {
    private let runtime: ChatRuntime
    private let account = AccountField(key: "contacts.account", identifier: "chat.friend.account")
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(runtime: ChatRuntime) { self.runtime = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.addFriend" }
    override func viewDidLoad() {
        super.viewDidLoad()
        account.input.autocapitalizationType = .none; account.input.autocorrectionType = .no
        account.input.semanticContentAttribute = .forceLeftToRight; account.input.returnKeyType = .search
        account.input.addAction(UIAction { [weak self] _ in self?.invalidate(); self?.statusKey = nil }, for: .editingChanged)
        account.input.addAction(UIAction { [weak self] _ in self?.lookup() }, for: .primaryActionTriggered)
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }
        account.reloadText()
        fields = [text(Localization.text("chat.live.addHelp")), account]
        controls = [action("chat.live.lookup", primary: true) { [weak self] in self?.lookup() }]
        updateBusy(); setNeedsQuickLayout()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); invalidate() }
    private func invalidate() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    private func lookup() {
        guard !busy, let api = runtime.api, let engine = runtime.engine else { return }
        let value = (account.input.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { statusKey = "contacts.invalidInput"; return }
        busy = true; statusKey = nil; let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { busy = false; task = nil } }
            do {
                let user = try await api.lookup(account: value)
                guard self.generation == generation, runtime.engine === engine, !Task.isCancelled else { return }
                guard user.id != runtime.userID else { statusKey = "chat.live.selfContact"; return }
                let contact = try await runtime.refreshContact(peer: user.id)
                guard self.generation == generation, runtime.engine === engine, !Task.isCancelled else { return }
                account.input.resignFirstResponder()
                navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: contact), animated: true)
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                report(error)
            }
        }
    }
    deinit { task?.cancel() }
}
