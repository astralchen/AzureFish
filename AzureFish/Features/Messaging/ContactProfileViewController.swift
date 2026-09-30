import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 联系人表单使用独立滚动容器；重绘资料不替换正在编辑的输入对象。
class ContactFormController: LocalizedQuickLayoutHostingController {
    let scroll = QuickLayoutScrollView()
    var fields: [UIView] = []
    var controls: [UIButton] = []
    let status = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    var statusKey: String? { didSet { status.text = statusKey.map { Localization.text($0) }; setNeedsQuickLayout() } }
    var busy = false { didSet { updateBusy() } }
    override var body: Layout {
        ScrollView(scroll) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(fields) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity) }
                if busy { activity.frame(width: 44, height: 44) }
                status.resizable(axis: .horizontal)
                ForEach(controls) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 48) }
            }.frame(width: min(560, max(0, view.bounds.width - 40))).padding(.vertical, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaPadding(.all, 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad(); quickLayoutKeyboardSafeAreaBehavior = .docked()
        view.backgroundColor = .systemGroupedBackground; scroll.keyboardDismissMode = .interactive
        navigationItem.largeTitleDisplayMode = .never
        status.font = .preferredFont(forTextStyle: .footnote); status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0; status.textColor = .secondaryLabel; status.accessibilityIdentifier = "contacts.status"
    }
    func text(_ value: String, style: UIFont.TextStyle = .body) -> UILabel {
        let label = UILabel(); label.text = value; label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style); label.adjustsFontForContentSizeCategory = true
        return label
    }
    func action(_ key: String, primary: Bool = false, destructive: Bool = false, perform: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var config = primary ? UIButton.Configuration.filled() : .plain()
        config.title = Localization.text(key); config.baseForegroundColor = destructive ? .systemRed : primary ? nil : .label
        if !primary { config.background.backgroundColor = .secondarySystemGroupedBackground }
        config.cornerStyle = .large; config.contentInsets = .init(top: 14, leading: 16, bottom: 14, trailing: 16)
        button.configuration = config; button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = key
        button.addAction(UIAction { _ in perform() }, for: .touchUpInside)
        return button
    }
    func updateBusy() {
        controls.forEach { $0.isEnabled = !busy; $0.configuration?.showsActivityIndicator = false }
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
        setNeedsQuickLayout()
        navigationItem.rightBarButtonItem?.isEnabled = !busy
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        status.text = statusKey.map { Localization.text($0) }
    }
    func report(_ error: any Error) { statusKey = contactErrorKey(error) }
}

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

/// 显示当前账号可见的资料和操作；只根据权威返回值更新关系。
final class FriendViewController: ContactFormController {
    private let runtime: ChatRuntime
    private var contact: ChatContact
    private var observation: UUID?
    private let avatar = AccountAvatarView()
    init(runtime: ChatRuntime, contact: ChatContact) {
        self.runtime = runtime
        self.contact = runtime.contacts.first { $0.peer.id == contact.peer.id }.map { contact.merging($0) } ?? contact
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.live.friendProfile" }
    override func viewDidLoad() {
        super.viewDidLoad()
        observation = runtime.observe { [weak self] in
            guard let self, let value = runtime.contacts.first(where: { $0.peer.id == contact.peer.id }) else { return }
            let merged = contact.merging(value)
            guard merged != contact else { return }
            contact = merged; render()
        }
        render()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureAvatar()
        Task { [weak self] in
            guard let self else { return }
            _ = try? await runtime.refreshContact(peer: contact.peer.id)
        }
    }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); if isViewLoaded { render() } }
    private func configureAvatar() {
        if let user = UUID(uuidString: contact.peer.id) { avatar.configure(session: runtime.session, user: user, asset: contact.peer.deleted == true ? nil : contact.peer.avatarID) }
        else { avatar.reset() }
    }
    private func render() {
        configureAvatar()
        avatar.isAccessibilityElement = true
        avatar.accessibilityIdentifier = "contacts.profile.avatar"
        // 表单项会横向撑满；由独立容器保持头像的方形尺寸。
        let avatarRow = QuickLayoutView { [avatar] in
            avatar.resizable().frame(width: 64, height: 64)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        fields = [avatarRow, text(contact.peer.deleted == true ? Localization.text("account.deletedUser") : contact.displayName, style: .title1)]
        if !contact.remark.isEmpty { fields.append(text(contact.peer.nickname, style: .subheadline)) }
        if contact.isBlocked { fields.append(text(Localization.text("contacts.blockedHelp"), style: .footnote)) }
        if !contact.requestID.isEmpty {
            fields += [text(Localization.text("contacts.request." + contact.requestState), style: .footnote)]
            if !contact.requestMessage.isEmpty { fields.append(text(contact.requestMessage)) }
        }
        controls = []
        if contact.allows(.remark) {
            controls.append(action("contacts.remark") { [weak self] in self?.edit(.remark) })
        }
        if contact.canSend {
            controls.append(action("chat.live.sendMessage", primary: true) { [weak self] in self?.openChat() })
        }
        if contact.allows(.restore) {
            controls.append(action("contacts.restore", primary: true) { [weak self] in self?.mutate(.restore) })
        } else if contact.allows(.request) {
            controls.append(action("chat.live.request", primary: true) { [weak self] in self?.edit(.request) })
        }
        for (action, key) in [(ContactAction.accept, "chat.live.accept"), (.reject, "chat.live.reject"), (.cancel, "chat.live.cancelRequest")] where contact.allows(action) {
            controls.append(self.action(key, primary: action == .accept) { [weak self] in self?.mutate(action) })
        }
        if contact.semanticsVersion != 2 { fields.append(text(Localization.text("contacts.updateRequired"))) }
        else if !contact.canSend && contact.isContact && !contact.isBlocked && contact.requestState != "pending" {
            fields.append(text(Localization.text("chat.live.friendRequired"), style: .footnote))
        }
        let manage = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            navigationController?.pushViewController(ContactManagementViewController(runtime: runtime, contact: contact), animated: true)
        })
        manage.accessibilityLabel = Localization.text("contacts.manage"); navigationItem.rightBarButtonItem = manage
        updateBusy(); setNeedsQuickLayout()
    }
    private func edit(_ action: ContactAction) {
        navigationController?.pushViewController(ContactEditViewController(runtime: runtime, contact: contact, action: action), animated: true)
    }
    private func mutate(_ action: ContactAction) {
        guard !busy else { return }; busy = true
        Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do { contact = try await runtime.contactOperations.mutate(contact, action: action); statusKey = nil; render() }
            catch { if viewIfLoaded?.window != nil { report(error) } }
        }
    }
    private func openChat() {
        guard !busy else { return }
        guard let engine = runtime.engine, let openConversation = runtime.openConversation else {
            report(ContactOperationError.unavailable)
            return
        }
        busy = true; statusKey = nil
        Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do {
                let conversation = try await runtime.directConversation(for: contact)
                guard runtime.engine === engine, viewIfLoaded?.window != nil else { return }
                openConversation(conversation)
            } catch { if runtime.engine === engine, viewIfLoaded?.window != nil { report(error) } }
        }
    }
    deinit { if let observation { let runtime = runtime; Task { @MainActor in runtime.remove(observation) } } }
}

/// 备注和申请留言编辑页；语言及关系刷新不替换输入内容。
final class ContactEditViewController: ContactFormController {
    private let runtime: ChatRuntime
    private var contact: ChatContact
    private let operation: ContactAction
    private let input: AccountField
    init(runtime: ChatRuntime, contact: ChatContact, action: ContactAction) {
        self.runtime = runtime; self.contact = contact; self.operation = action
        input = AccountField(key: action == .remark ? "contacts.remark" : "contacts.message", identifier: "contacts.editor")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { operation == .remark ? "contacts.remark" : "chat.live.request" }
    override func viewDidLoad() {
        super.viewDidLoad(); input.input.text = operation == .remark ? contact.remark : ""
        input.input.addAction(UIAction { [weak self] _ in self?.statusKey = nil }, for: .editingChanged)
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }; input.reloadText()
        fields = [text(contact.displayName, style: .title2), input,
                  text(Localization.text(operation == .remark ? "contacts.remarkHelp" : "contacts.messageHelp"), style: .footnote)]
        controls = [action(operation == .remark ? "contacts.save" : "chat.live.request", primary: true) { [weak self] in self?.save() }]
        updateBusy(); setNeedsQuickLayout()
    }
    override func updateBusy() { super.updateBusy(); input.input.isEnabled = !busy }
    private func save() {
        guard !busy, let engine = runtime.engine else { return }
        let value = input.input.text ?? ""
        guard value.count <= (operation == .remark ? 64 : 200),
              (value.isEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) else {
            statusKey = "contacts.invalidInput"; setNeedsQuickLayout(); return
        }
        busy = true
        Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do {
                contact = try await runtime.contactOperations.mutate(contact, action: operation,
                    remark: operation == .remark ? value : "", message: operation == .request ? value : "")
                guard runtime.engine === engine, navigationController?.topViewController === self else { return }
                input.input.resignFirstResponder(); navigationController?.popViewController(animated: true)
            } catch {
                guard runtime.engine === engine else { return }
                if let fresh = runtime.contacts.first(where: { $0.peer.id == contact.peer.id }) { contact = fresh }
                report(error)
            }
        }
    }
}

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
#Preview("好友资料") { AppNavigationController(rootViewController: FriendViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact)) }
@available(iOS 17.0, *)
#Preview("好友管理") { ContactManagementViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact) }
@available(iOS 17.0, *)
#Preview("备注编辑") { ContactEditViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact, action: .remark) }
#endif
