import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

struct ContactSection: Equatable {
    let id: String
    let contacts: [ChatContact]
}

/// 通讯录排序与分组只使用显示语言；用户身份及账号规范化不变。
enum ContactDirectoryPresentation {
    static func sections(_ contacts: [ChatContact], query: String, locale: Locale) -> [ContactSection] {
        let values = contacts.filter { $0.isContact && !$0.isBlocked && $0.matches(query) }.sorted {
            let order = $0.displayName.compare($1.displayName, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return order == .orderedSame ? $0.peer.id < $1.peer.id : order == .orderedAscending
        }
        let groups = Dictionary(grouping: values) { contact -> String in
            var name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if locale.identifier.hasPrefix("zh") { name = name.applyingTransform(.toLatin, reverse: false) ?? name }
            name = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale).uppercased(with: locale)
            guard let first = name.first, first.isLetter else { return "#" }
            return String(first)
        }
        return groups.keys.sorted {
            if $0 == "#" { return false }; if $1 == "#" { return true }
            return $0.compare($1, locale: locale) == .orderedAscending
        }.map { ContactSection(id: $0, contacts: groups[$0]!) }
    }
}

/// 好友、申请和黑名单的专属列表，共享权威投影及 ListKit 分组索引。
class ContactDirectoryController: LocalizedQuickLayoutHostingController, UISearchResultsUpdating, UISearchControllerDelegate {
    enum Mode { case contacts, requests, blocked }
    let runtime: ChatRuntime
    let mode: Mode
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    let sectionIndex = CollectionSectionIndexView()
    private let search = UISearchController(searchResultsController: nil)
    private let stateView = ChatListStateView(frame: .zero)
    private var isSearching = false
    private var observation: UUID?
    private var busy = Set<String>()
    var showProfile: ((ChatContact) -> Void)?
    init(runtime: ChatRuntime, mode: Mode) { self.runtime = runtime; self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? {
        switch mode { case .contacts: "chat.live.contacts"; case .requests: "chat.live.newFriends"; case .blocked: "contacts.blacklist" }
    }
    override var body: Layout {
        HStack(spacing: 0) {
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            if mode == .contacts && !sectionIndex.titles.isEmpty {
                sectionIndex.resizable().frame(width: 44).frame(maxHeight: .infinity)
            }
        }.safeAreaPadding(.horizontal)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        list.backgroundColor = .clear; list.alwaysBounceVertical = true
        list.contentInsetAdjustmentBehavior = .automatic
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        list.accessibilityIdentifier = "contacts.list"
        if mode == .contacts { adapter.sectionIndexView = sectionIndex }
        sectionIndex.accessibilityIdentifier = "contacts.index"
        setContentScrollView(list, for: .top)
        navigationItem.searchController = search; search.searchResultsUpdater = self; search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.largeTitleDisplayMode = mode == .contacts ? .always : .never
        navigationController?.navigationBar.prefersLargeTitles = true
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in Task { await self?.runtime.refreshAndWait(); refresh?.endRefreshing() } }, for: .valueChanged)
        list.refreshControl = refresh
        stateView.content.retry = { [weak self] in self?.runtime.refresh() }
        observation = runtime.observe { [weak self] in self?.render() }
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        guard isViewLoaded else { return }
        search.searchBar.placeholder = Localization.text("chat.live.search")
        sectionIndex.accessibilityLabel = Localization.text("contacts.index")
        if mode != .blocked {
            let add = UIBarButtonItem(image: UIImage(systemName: "person.badge.plus"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                navigationController?.pushViewController(AddFriendViewController(runtime: runtime), animated: true)
            })
            add.accessibilityLabel = Localization.text("chat.live.addFriend")
            navigationItem.rightBarButtonItem = add
        }
        render()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 横向安全区域已由 HStack 消费；纵向只使用列表已合并导航栏／底部栏的 inset。
        let adjusted = list.adjustedContentInset
        sectionIndex.contentInsets = UIEdgeInsets(top: adjusted.top, left: 0, bottom: adjusted.bottom, right: 0)
        var inset = list.adjustedContentInset
        if mode == .contacts, search.searchBar.text?.isEmpty != false,
           let frame = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame {
            inset.top += max(0, frame.maxY - list.contentOffset.y - inset.top)
        }
        stateView.viewportInsets = inset
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { render() }
    }
    func updateSearchResults(for searchController: UISearchController) { render() }
    func willPresentSearchController(_ searchController: UISearchController) { isSearching = true; render() }
    func didDismissSearchController(_ searchController: UISearchController) { isSearching = false; render() }
    private func open(_ contact: ChatContact) {
        if let showProfile { showProfile(contact) }
        else { navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: contact), animated: true) }
    }
    private func accept(_ contact: ChatContact) {
        guard !busy.contains(contact.peer.id) else { return }
        busy.insert(contact.peer.id); render()
        Task { [weak self] in
            guard let self else { return }
            defer { busy.remove(contact.peer.id); render() }
            do { _ = try await runtime.contactOperations.mutate(contact, action: .accept) }
            catch { if viewIfLoaded?.window != nil { showContactMessage(contactErrorKey(error)) } }
        }
    }
    private func render() {
        guard isViewLoaded else { return }
        let query = search.searchBar.text ?? ""
        let locale = Locale(identifier: Localization.localizationController.currentLocale.identifier)
        let all: [ChatContact]
        switch mode {
        case .contacts: all = runtime.contacts.filter { $0.isContact && !$0.isBlocked }
        case .requests: all = runtime.contacts.filter { !$0.requestID.isEmpty }
        case .blocked: all = runtime.contacts.filter(\.isBlocked)
        }
        let matches = all.filter { $0.matches(query) }
        let groups = mode == .contacts ? ContactDirectoryPresentation.sections(all, query: query, locale: locale)
            : [ContactSection(id: "records", contacts: matches.sorted {
                $0.requestUpdatedAt == $1.requestUpdatedAt ? $0.peer.id < $1.peer.id : $0.requestUpdatedAt > $1.requestUpdatedAt
            })]
        let pending = runtime.contacts.filter { $0.requestState == "pending" && $0.requesterID != runtime.userID && !$0.isBlocked }.count
        let state = ChatListContentState.resolve(hasSnapshot: runtime.hasSnapshot, synchronization: runtime.synchronization,
            storageFailure: runtime.failure != nil, totalCount: all.count, matchCount: matches.count, searching: !query.isEmpty)
        stateView.content.configure(state)
        if state == .empty {
            let key = mode == .contacts ? "chat.live.emptyContacts" : mode == .requests ? "contacts.noRequests" : "contacts.noBlocked"
            stateView.content.titleLabel.text = Localization.text(key)
            stateView.content.detailLabel.text = mode == .contacts ? Localization.text("chat.live.addHelp") : ""
        }
        list.backgroundView = state == .content ? nil : stateView
        let count = Localization.text("contacts.count", all.count)
        let footer = [mode == .contacts ? count : "", runtime.online ? "" : Localization.text("chat.live.offline")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let showEntry = mode == .contacts && query.isEmpty
        adapter.apply(transaction: .disabled, completion: { [weak self] _ in
            self?.setNeedsQuickLayout()
        }) {
            if showEntry {
                ListSection("entry") {
                    Row("requests", model: pending, cell: UICollectionViewListCell.self) { cell, count, _ in
                        var c = UIListContentConfiguration.cell()
                        c.text = Localization.text("chat.live.newFriends")
                        c.image = UIImage(systemName: "person.badge.plus"); c.imageProperties.tintColor = .systemBlue
                        c.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 20, trailing: 20)
                        cell.contentConfiguration = c; cell.accessories = [.disclosureIndicator()]
                        if count > 0 {
                            let badge = UnreadCountBadgeView(text: count > 99 ? "99+" : String(count))
                            cell.accessories.insert(.customView(configuration: .init(customView: badge, placement: .trailing(), reservedLayoutWidth: .actual, maintainsFixedSize: true)), at: 0)
                        }
                        cell.accessibilityIdentifier = "contacts.requests"
                        cell.accessibilityLabel = Localization.text("chat.live.newFriends") + (count > 0 ? ", " + String(count) : "")
                    }.onSelect { [weak self] _, _ in
                        guard let self else { return }
                        let requests = FriendRequestsViewController(runtime: runtime)
                        requests.showProfile = showProfile
                        navigationController?.pushViewController(requests, animated: true)
                    }
                }.layout(Self.sectionLayout("entry", header: false))
            }
            for group in groups {
                ListSection(group.id) {
                    ListKit.ForEach(group.contacts, id: \.peer.id) { contact in
                        if self.mode == .requests {
                            Row(contact.peer.id, model: contact, cell: ContactRequestCell.self) { [weak self] cell, contact, _ in
                                guard let self else { return }
                                cell.configure(contact, detail: requestDetail(contact, locale: locale), busy: busy.contains(contact.peer.id)) { [weak self] in self?.accept(contact) }
                            }.onSelect { [weak self] contact, _ in self?.open(contact) }
                        } else {
                            Row(contact.peer.id, model: contact, cell: UICollectionViewListCell.self) { [weak self] cell, contact, _ in
                                self?.configure(cell, contact: contact, locale: locale)
                            }.onSelect { [weak self] contact, _ in self?.open(contact) }
                        }
                    }
                }.sectionSupplementaries {
                    if self.mode == .contacts {
                        Header(UICollectionViewListCell.self, id: group.id + ".heading") { cell, _ in
                            var c = UIListContentConfiguration.groupedHeader()
                            c.text = group.id; cell.contentConfiguration = c
                        }.layout(extendsBoundary: true)
                    }
                    if group.id == groups.last?.id && !matches.isEmpty && !footer.isEmpty {
                        Footer(UICollectionViewListCell.self, id: group.id + ".footer." + footer) { cell, _ in
                            var c = UIListContentConfiguration.groupedFooter()
                            c.text = footer; c.textProperties.alignment = .center; c.textProperties.numberOfLines = 0
                            cell.contentConfiguration = c
                            cell.accessibilityIdentifier = "contacts.footer"
                        }.layout(extendsBoundary: true)
                    }
                }.indexTitle(self.mode == .contacts && query.isEmpty && !self.isSearching ? group.id : nil)
                    .layout(Self.sectionLayout(group.id, header: false))
            }

        }
        adapter.reconfigureRows(forRowIDs: matches.map(\.peer.id), transaction: .disabled, completion: nil)
    }
    private func requestDetail(_ contact: ChatContact, locale: Locale) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.dateStyle = .medium; formatter.timeStyle = .none
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(contact.requestUpdatedAt) / 1000))
        return [Localization.text(contact.requesterID == runtime.userID ? "chat.live.outgoing" : "chat.live.incoming"), contact.requestMessage, Localization.text("contacts.request." + contact.requestState), date].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func configure(_ cell: UICollectionViewListCell, contact: ChatContact, locale: Locale) {
        var c = UIListContentConfiguration.subtitleCell()
        c.text = contact.peer.deleted == true ? Localization.text("account.deletedUser") : contact.displayName
        c.textProperties.numberOfLines = 0; c.secondaryTextProperties.numberOfLines = 0
        c.secondaryTextProperties.color = .secondaryLabel
        c.image = nil
        c.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        c.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        if !contact.remark.isEmpty { c.secondaryText = contact.peer.nickname }
        let large = cell.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        if large { c.image = nil }
        cell.contentConfiguration = c; cell.accessories = [.disclosureIndicator()]
        if let user = UUID(uuidString: contact.peer.id) {
            let avatar = AccountAvatarView()
            avatar.configure(session: runtime.session, user: user, asset: contact.peer.avatarID)
            avatar.frame.size = CGSize(width: 44, height: 44); avatar.contentMode = .scaleAspectFit
            avatar.isAccessibilityElement = false
            cell.accessories.append(.customView(configuration: .init(customView: avatar, placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true)))
        }
        cell.accessibilityIdentifier = "contacts.peer." + contact.peer.id
    }

    private static func sectionLayout(_ id: String, header: Bool) -> ListCustomSectionLayout<String> {
        ListCustomSectionLayout(id: id) { _, _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear; config.headerMode = header ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }
    deinit {
        if let observation { let runtime = runtime; Task { @MainActor in runtime.remove(observation) } }
    }
}
final class ContactsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .contacts) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
final class FriendRequestsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .requests) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
final class BlockedContactsViewController: ContactDirectoryController {
    init(runtime: ChatRuntime) { super.init(runtime: runtime, mode: .blocked) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
/// 申请行的大字体布局将操作放在正文之后，避免 RTL 混合文字与头像环绕重叠。
final class ContactRequestCell: QuickLayoutCollectionViewCell {
    private let avatar = UIImageView()
    private let name = UILabel(), detail = UILabel()
    private let accept = UIButton(type: .system)
    private let separator = UIView()
    private var canAccept = false
    private var accepted: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        for label in [name, detail] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        name.font = .preferredFont(forTextStyle: .body); detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel; avatar.contentMode = .scaleAspectFit
        separator.backgroundColor = .separator
        accept.addAction(UIAction { [weak self] _ in self?.accepted?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                avatar.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) { name.resizable(axis: .horizontal); detail.resizable(axis: .horizontal) }
                    .frame(maxWidth: .infinity)
            }
            if canAccept { accept.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 44) }
            separator.resizable(axis: .horizontal).frame(height: 0.5)
        }.padding(.horizontal, 20).padding(.top, 16)
    }
    func configure(_ contact: ChatContact, detail: String, busy: Bool, accepted: @escaping () -> Void) {
        name.text = contact.displayName; self.detail.text = detail; avatar.image = ContactAvatar.image
        name.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        self.detail.textAlignment = name.textAlignment
        canAccept = contact.allows(.accept); self.accepted = accepted
        var config = UIButton.Configuration.tinted(); config.title = Localization.text("chat.live.accept")
        config.showsActivityIndicator = busy; accept.configuration = config; accept.isEnabled = !busy
        accept.titleLabel?.numberOfLines = 0
        accept.accessibilityIdentifier = "contacts.accept." + contact.peer.id
        accessibilityIdentifier = "contacts.peer." + contact.peer.id
        setNeedsQuickLayout()
    }
}

@MainActor
enum ContactAvatar {
    static var image: UIImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48), format: format).image { _ in
            UIColor.systemBlue.withAlphaComponent(0.12).setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 48, height: 48), cornerRadius: 10).fill()
            UIImage(systemName: "person.fill")?.withTintColor(.systemBlue).draw(in: CGRect(x: 12, y: 11, width: 24, height: 26))
        }
    }
}

extension UIViewController {
    func showContactMessage(_ key: String) {
        let alert = UIAlertController(title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        present(alert, animated: true)
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("通讯录") { UINavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
@available(iOS 17.0, *)
#Preview("通讯录 · 字母索引") { UINavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.indexedContacts))) }
@available(iOS 17.0, *)
#Preview("空通讯录") { UINavigationController(rootViewController: ContactsViewController(runtime: ChatRuntime(previewContacts: []))) }
@available(iOS 17.0, *)
#Preview("新的朋友") { UINavigationController(rootViewController: FriendRequestsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
@available(iOS 17.0, *)
#Preview("黑名单") { UINavigationController(rootViewController: BlockedContactsViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts))) }
@available(iOS 17.0, *)
#Preview("好友申请行") {
    let cell = ContactRequestCell(frame: CGRect(x: 0, y: 0, width: 390, height: 260))
    cell.configure(ConversationPreviewData.contacts[2], detail: "你好，我们在设计活动中见过。\n等待确认", busy: false, accepted: {})
    return QuickLayoutHostingController { cell.resizable(axis: .horizontal) }
}
#endif
