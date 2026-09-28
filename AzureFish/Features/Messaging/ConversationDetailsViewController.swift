import AppLocalization
import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 展示会话成员、真实设置及按权限开放的群管理操作。
final class ConversationDetailsViewController: LocalizedQuickLayoutHostingController {
    let runtime: ChatRuntime
    private var conversation: ChatConversation
    private let allMembers: Bool
    private let locate: (ChatMessage) async throws -> Void
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    private var observation: UUID?
    private var operations: [String: UUID] = [:]
    private var busy = false
    private var savingPreference = false
    private var pendingPreferences: ConversationLocalPreferences?
    private var ready = false
    private var columns = 4
    private var lastWidth: CGFloat = 0
    var conversationID: String { conversation.id }
    private var canManage: Bool {
        !conversation.closed && conversation.ownerID == runtime.userID
            && conversation.members.contains { $0.id == runtime.userID && $0.active }
    }
    init(runtime: ChatRuntime, conversation: ChatConversation, allMembers: Bool = false,
         locate: @escaping (ChatMessage) async throws -> Void = { _ in }) {
        self.runtime = runtime; self.conversation = conversation; self.allMembers = allMembers; self.locate = locate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { allMembers ? "chat.details.members" : "chat.live.details" }
    override var body: Layout {
        ZStack {
            list.resizable().frame(maxWidth: 640, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        list.backgroundColor = .clear
        list.alwaysBounceVertical = true
        list.contentInsetAdjustmentBehavior = .automatic
        list.accessibilityIdentifier = "chat.details.list"
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        navigationItem.largeTitleDisplayMode = .never
        setContentScrollView(list, for: .top)
        ready = true
        observation = runtime.observe { [weak self] in self?.reloadRows() }
        reloadRows()

    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reloadRows() }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); render() }
    override func reloadLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        super.reloadLayoutDirection(direction)
        list.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        list.collectionViewLayout.invalidateLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = min(640, list.bounds.width)
        let next = max(2, Int((width - 24) / (traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 130 : 76)))
        if columns != next || abs(lastWidth - width) > 0.5 {
            columns = next; lastWidth = width; list.collectionViewLayout.invalidateLayout(); render()
        }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { lastWidth = 0; view.setNeedsLayout(); render() }
    }
    private func reloadRows() {
        if let current = runtime.conversations.first(where: { $0.id == conversation.id }), current.revision >= conversation.revision { conversation = current }
        render()
    }
    private func render() {
        guard ready else { return }
        let members = conversation.members.filter { conversation.kind == "group" ? $0.active : $0.id != runtime.userID }
        let visible = allMembers ? members : Array(members.prefix(columns * 2))
        let values = pendingPreferences ?? runtime.preference(conversation.id)
        var groups: [[String]] = []
        if !allMembers {
            if members.count > visible.count { groups.append(["members"]) }
            if conversation.kind == "group" {
                groups.append(canManage ? ["rename", "add"] : ["title"])
            }
            groups += [["search"], ["mute", "pin"], ["clear"]]
            if conversation.kind == "group", !conversation.closed,
               conversation.members.contains(where: { $0.id == runtime.userID && $0.active }) {
                groups.append([canManage ? "dissolve" : "leave"])
            }
        }
        let cols = columns
        let ownerID = conversation.ownerID
        let backgroundInset = max(0, (list.bounds.width - 640) / 2)
        let locale = Localization.localizationController.currentLocale.identifier
        let rowRevision = "\(values.isPinned):\(values.isMuted):\(savingPreference):\(busy):\(conversation.title):\(locale):\(traitCollection.preferredContentSizeCategory.rawValue)"
        adapter.apply(transaction: .disabled) {
            ListSection("avatars") {
                ListKit.ForEach(visible, id: \.id) { member in
                    Row(member.id, model: runtime.memberName(member), cell: ConversationMemberCell.self) { cell, name, _ in
                        cell.configure(name: name, owner: member.id == ownerID)
                        cell.accessibilityIdentifier = "chat.details.member." + member.id
                    }.refreshID([ownerID, locale, runtime.memberName(member), traitCollection.preferredContentSizeCategory.rawValue]).onSelect { [weak self] _, _ in self?.openMember(member) }
                }
            }.background {
                ListBackgroundDecoration(view: ConversationMembersBackground.self, contentInsets: .init(leading: backgroundInset, trailing: backgroundInset))
            }.layout(.custom(id: "avatars") { _, _, environment in
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(cols)), heightDimension: .estimated(110)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(110)), subitem: item, count: cols)
                let section = NSCollectionLayoutSection(group: group)
                let inset = max(12, (environment.container.effectiveContentSize.width - 640) / 2)
                section.contentInsets = .init(top: 16, leading: inset, bottom: 16, trailing: inset)
                return section
            })
            for (index, ids) in groups.enumerated() {
                ListSection("group-\(index)") {
                    ListKit.ForEach(ids, id: \.self) { id in
                        Row(id, model: id + rowRevision, cell: UICollectionViewListCell.self) { [weak self] cell, _, _ in
                            self?.configure(cell, id: id)
                        }.onSelect { [weak self] _, _ in
                            guard let self, !busy else { return }
                            list.indexPathsForSelectedItems?.forEach { list.deselectItem(at: $0, animated: true) }
                            perform(id)
                        }
                    }
                }.layout(.custom(id: "group-\(index)") { _, _, environment in
                    var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                    configuration.backgroundColor = .clear
                    let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                    let inset = max(0, (environment.container.effectiveContentSize.width - 640) / 2)
                    section.contentInsets = .init(top: 0, leading: inset, bottom: 12, trailing: inset)
                    return section
                })
            }
        }
    }
    private func configure(_ cell: UICollectionViewListCell, id: String) {
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = .secondarySystemGroupedBackground
        cell.backgroundConfiguration = background
        let keys = ["search": "chat.details.search", "mute": "chat.details.mute", "pin": "chat.details.pin", "members": "chat.details.members", "title": "chat.details.groupName", "rename": "chat.details.groupName"]
        let title = Localization.text(keys[id] ?? "chat.live." + (id == "clear" ? "clearLocal" : id == "add" ? "addMembers" : id))
        var content = id == "mute" ? UIListContentConfiguration.subtitleCell() : UIListContentConfiguration.valueCell()
        content.text = title
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        let destructive = ["clear", "leave", "dissolve"].contains(id)
        content.textProperties.color = destructive ? .systemRed : .label
        content.textProperties.alignment = destructive ? .center : .natural
        content.directionalLayoutMargins = .init(top: 16, leading: 20, bottom: 16, trailing: 20)
        if id == "title" || id == "rename" { content.secondaryText = conversation.title }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "chat.details." + id
        cell.accessories = id == "title" || destructive ? [] : [.disclosureIndicator()]
        cell.isUserInteractionEnabled = !busy
        if id == "mute" || id == "pin" {
            let toggle = UISwitch()
            let value = pendingPreferences ?? runtime.preference(conversation.id)
            toggle.isOn = id == "mute" ? value.isMuted : value.isPinned
            toggle.isEnabled = !savingPreference
            toggle.accessibilityLabel = title
            toggle.accessibilityIdentifier = "chat.details." + id + ".switch"
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let self, let toggle else { return }
                updatePreference(id, enabled: toggle.isOn)
            }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing()))]
            if id == "mute" {
                content.secondaryText = Localization.text("chat.details.muteHelp")
                cell.contentConfiguration = content
            }
        }
    }
    private func updatePreference(_ id: String, enabled: Bool) {
        guard !savingPreference else { return }
        var value = runtime.preference(conversation.id)
        if id == "mute" { value.isMuted = enabled } else { value.isPinned = enabled }
        savingPreference = true
        pendingPreferences = value
        render()
        Task { [weak self] in
            guard let self else { return }
            defer { savingPreference = false; pendingPreferences = nil; render() }
            do { try await runtime.updatePreference(conversation: conversation.id, isPinned: id == "pin" ? enabled : nil, isMuted: id == "mute" ? enabled : nil) }
            catch { showError(error) }
        }
    }
    private func showError(_ error: Error) {
        let key: String
        if case APIClientError.service(let failure) = error, failure.code == .conversationVersionConflict { key = "chat.live.changed" }
        else { key = "chat.live.failed" }
        let alert = UIAlertController(title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
        let presenter = navigationController?.visibleViewController ?? self
        if presenter.presentedViewController is UIAlertController {
            presenter.dismiss(animated: true) { presenter.present(alert, animated: true) }
        } else if presenter.presentedViewController == nil { presenter.present(alert, animated: true) }
    }
    private func perform(_ id: String) {
        switch id {
        case "pin": updatePreference(id, enabled: !runtime.preference(conversation.id).isPinned)
        case "mute": updatePreference(id, enabled: !runtime.preference(conversation.id).isMuted)
        case "search":
            navigationController?.pushViewController(ConversationSearchViewController(runtime: runtime, conversation: conversation, locate: locate), animated: true)
        case "members":
            navigationController?.pushViewController(ConversationDetailsViewController(runtime: runtime, conversation: conversation, allMembers: true, locate: locate), animated: true)
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
                        guard let engine = runtime.engine else { throw ChatStoreError.unavailable }
                        try await engine.store.clear(conversation: conversation.id)
                        guard runtime.engine === engine else { return }
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
            if id.hasPrefix("member:"), let value = conversation.members.first(where: { $0.id == String(id.dropFirst(7)) }) {
                openMember(value)
            }
        }
    }
    private func openMember(_ member: ChatMember) {
        list.indexPathsForSelectedItems?.forEach { list.deselectItem(at: $0, animated: false) }
        if member.id == runtime.userID {
            navigationController?.pushViewController(ProfileViewController(session: runtime.session, runtime: runtime), animated: true)
            return
        }
        if conversation.kind != "group", let contact = runtime.contacts.first(where: { $0.peer.id == member.id }) {
            navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: contact), animated: true)
            return
        }
        let page = ConversationMemberViewController(runtime: runtime, member: member, conversationID: conversation.id)
        if canManage {
            page.manage = { [weak self] action, completion in
                guard let self else { completion(false); return }
                change(action, member: member.id, completion: completion)
            }
        }
        navigationController?.pushViewController(page, animated: true)
    }
    private func chooseFriend() {
        let chooser = LiveChatListController(runtime: runtime)
        chooser.title = Localization.text("chat.live.addMembers")
        chooser.rows = runtime.contacts.filter { contact in
            contact.canSend
                && !conversation.members.contains(where: { $0.id == contact.peer.id && $0.active })
        }.map { LiveChatRow(id: $0.peer.id, title: $0.displayName) }
        chooser.selected = { [weak self, weak chooser] id in
            self?.change(.add, member: id) { success in
                if success { chooser?.navigationController?.popViewController(animated: true) }
            }
        }
        navigationController?.pushViewController(chooser, animated: true)
    }
    private func change(_ action: GroupAction, title: String = "", member: String = "", completion: ((Bool) -> Void)? = nil) {
        guard !busy else { completion?(false); return }
        guard let api = runtime.api, let engine = runtime.engine else {
            showError(ChatStoreError.unavailable); completion?(false); return
        }
        busy = true
        render()
        let key = "\(action.rawValue):\(conversation.revision):\(title):\(member)"
        let id = operations[key] ?? UUID()
        operations[key] = id
        Task {
            var succeeded = false
            defer { busy = false; render(); completion?(succeeded) }
            do {
                let result = try await api.updateGroup(
                    conversation.id, revision: conversation.revision, action: action, title: title, member: member,
                    operationID: id)
                guard runtime.engine === engine else { return }
                conversation = result
                try await engine.store.save(result)
                succeeded = true
                runtime.changed()
                reloadRows()
            } catch {
                guard runtime.engine === engine else { return }
                if let current = try? await api.conversation(conversation.id), runtime.engine === engine {
                    try? await engine.store.save(current)
                    conversation = current
                    reloadRows()
                    runtime.changed()
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
    deinit {
        if let observation { let runtime = runtime; Task { @MainActor in runtime.remove(observation) } }
    }
}

/// 成员网格的头像和昵称，使用默认头像避免虚构服务器未提供的资料。
final class ConversationMemberCell: QuickLayoutCollectionViewCell {
    private let avatar = UIImageView(image: UIImage(systemName: "person.crop.square.fill"))
    private let name = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        avatar.tintColor = .secondaryLabel
        avatar.contentMode = .scaleAspectFit
        name.font = .preferredFont(forTextStyle: .footnote)
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 2
        name.textAlignment = .center
        contentView.backgroundColor = .secondarySystemGroupedBackground
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: .center, spacing: 6) {
            avatar.resizable().frame(width: 52, height: 52)
            name.resizable(axis: .horizontal)
        }.padding(.horizontal, 4).padding(.vertical, 8)
    }
    func configure(name: String, owner: Bool) {
        self.name.text = name
        accessibilityLabel = name
        accessibilityValue = owner ? Localization.text("chat.live.owner") : nil
        setNeedsQuickLayout()
    }
}

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
        guard !busy, let api = runtime.api, let engine = runtime.engine else { return }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false }
            do {
                let contact = try await api.contact(peer: member.id)
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
#Preview("聊天成员") {
    let cell = ConversationMemberCell(frame: CGRect(x: 0, y: 0, width: 100, height: 110))
    cell.configure(name: "林沐", owner: false)
    return cell
}
#endif

#if DEBUG
@available(iOS 17.0, *)
#Preview("聊天详情 · 群主") {
    UINavigationController(rootViewController: ConversationDetailsViewController(runtime: ConversationPreviewData.detailsRuntime(), conversation: ConversationPreviewData.detailsConversation()))
}
@available(iOS 17.0, *)
#Preview("聊天详情 · 单聊") {
    UINavigationController(rootViewController: ConversationDetailsViewController(runtime: ConversationPreviewData.detailsRuntime(), conversation: ConversationPreviewData.detailsConversation(group: false)))
}
@available(iOS 17.0, *)
#Preview("聊天详情 · 大字体 RTL") {
    let page = ConversationDetailsViewController(runtime: ConversationPreviewData.detailsRuntime(), conversation: ConversationPreviewData.detailsConversation(owner: false))
    page.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraLarge
    page.loadViewIfNeeded(); page.reloadLayoutDirection(.rightToLeft)
    return UINavigationController(rootViewController: page)
}
@available(iOS 17.0, *)
#Preview("群成员资料") {
    ConversationMemberViewController(runtime: ConversationPreviewData.detailsRuntime(), member: ConversationPreviewData.detailsConversation().members[1])
}
#endif

/// 为整个成员分组提供连续的语义背景。
private final class ConversationMembersBackground: UICollectionReusableView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .secondarySystemGroupedBackground }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("成员分组背景") { ConversationMembersBackground(frame: CGRect(x: 0, y: 0, width: 390, height: 120)) }
#endif
