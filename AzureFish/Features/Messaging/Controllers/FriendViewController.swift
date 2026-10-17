import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

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
        if contact.canSend {
            controls.append(action("moments.album") { [weak self] in
                guard let self else { return }
                navigationController?.pushViewController(MomentsViewController(runtime: runtime.moments, author: contact.peer.id), animated: true)
            })
        }
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

#if DEBUG
@available(iOS 17.0, *)
#Preview("好友资料") { AppNavigationController(rootViewController: FriendViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact)) }
#endif
