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

/// 通讯录按显示名称的中文拼音排序，使用 A–Z 分组，其他首字符归入末尾的 `#`。
///
/// 索引不随界面语言变化；备注优先级、用户身份及账号规范化不变。
enum ContactDirectoryPresentation {
    static func sections(_ contacts: [ChatContact], query: String) -> [ContactSection] {
        let locale = Locale(identifier: "en_US_POSIX")
        let values = contacts.filter { $0.isContact && !$0.isBlocked && $0.matches(query) }.map { contact in
            var name = contact.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.applyingTransform(.mandarinToLatin, reverse: false) ?? name
            name = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: locale).uppercased(with: locale)
            let section = name.first.map { ("A"..."Z").contains($0) ? String($0) : "#" } ?? "#"
            return (contact: contact, name: name, section: section)
        }.sorted {
            let order = $0.name.compare($1.name, locale: locale)
            return order == .orderedSame ? $0.contact.peer.id < $1.contact.peer.id : order == .orderedAscending
        }
        let groups = Dictionary(grouping: values, by: \.section)
        return groups.keys.sorted {
            if $0 == "#" { return false }; if $1 == "#" { return true }
            return $0 < $1
        }.map { ContactSection(id: $0, contacts: groups[$0]!.map(\.contact)) }
    }
}

/// 好友、申请和黑名单的专属列表，共享权威投影及 ListKit 分组索引。
class ContactDirectoryController: LocalizedQuickLayoutHostingController, UISearchResultsUpdating, UISearchControllerDelegate {
    private static let indexWidth: CGFloat = 44
    enum Mode { case contacts, requests, blocked }
    let runtime: ChatRuntime
    let mode: Mode
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    let sectionIndex = CollectionSectionIndexView()
    private let search = UISearchController(searchResultsController: nil)
    private let stateView = ChatListStateView(frame: .zero)
    private var searchPresentationActive = false
    private var keyboardFrame: CGRect?
    private var isSearching: Bool {
        searchPresentationActive || search.isActive || search.searchBar.searchTextField.isFirstResponder
    }
    private var observation: UUID?
    private var busy = Set<String>()
    private struct Presentation: Equatable {
        let groups: [ContactSection]
        let pending: Int
        let busy: Set<String>
        let query: String
        let searching: Bool
        let footer: String
        let appearance: String
        let online: Bool
        let state: ChatListContentState
    }
    private var presentation: Presentation?
    private var rowVersions: [String: UInt64] = [:]
    private struct GroupingInput: Equatable {
        let contacts: [ChatContact]
        let query: String
    }
    private var groupingInput: GroupingInput?
    private var cachedGroups: [ContactSection] = []
    var showProfile: ((ChatContact) -> Void)?
    init(runtime: ChatRuntime, mode: Mode) { self.runtime = runtime; self.mode = mode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? {
        switch mode { case .contacts: "chat.live.contacts"; case .requests: "chat.live.newFriends"; case .blocked: "contacts.blacklist" }
    }
    override var body: Layout {
        // 索引覆盖列表尾侧，避免缩窄整行背景及偏移页脚中心。
        ZStack(alignment: .trailing) {
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            if mode == .contacts && !sectionIndex.titles.isEmpty {
                sectionIndex.resizable().frame(width: Self.indexWidth).frame(maxHeight: .infinity)
            }
        }.safeAreaPadding(.horizontal)
    }
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
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
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
        observation = runtime.observe { [weak self] in self?.render() }
        reloadLocalizedContent()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 重新进入时仅重配现有行，让上次失败的头像重试；已显示头像保持原视图。
        presentation = nil
        render()
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
        updateViewport()
    }
    @objc private func keyboardChanged(_ notification: Notification) {
        keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? nil
            : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        updateViewport()
    }
    private func updateViewport() {
        var overlap: CGFloat = 0
        if let keyboardFrame, let window = view.window {
            let frame = list.convert(window.convert(keyboardFrame, from: window.screen.coordinateSpace), from: window)
            let intersection = list.bounds.intersection(frame)
            // 与会话列表一致，仅完整停靠键盘增加底部 inset；浮动键盘不占满整行。
            if !intersection.isNull, intersection.maxY >= list.bounds.maxY - 1,
               intersection.width >= list.bounds.width * 0.9 { overlap = intersection.height }
        }
        let systemBottom = max(0, list.adjustedContentInset.bottom - list.contentInset.bottom)
        let bottom = max(0, overlap - systemBottom)
        if abs(list.contentInset.bottom - bottom) > 0.5 { list.contentInset.bottom = bottom }
        // 横向安全区域已由容器消费；纵向只使用列表已合并导航栏／底部栏的 inset。
        let adjusted = list.adjustedContentInset
        let indexInsets = UIEdgeInsets(top: adjusted.top, left: 0, bottom: adjusted.bottom, right: 0)
        if sectionIndex.contentInsets != indexInsets { sectionIndex.contentInsets = indexInsets }
        var inset = list.adjustedContentInset
        if mode == .contacts, search.searchBar.text?.isEmpty != false,
           let frame = list.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame {
            inset.top += max(0, frame.maxY - list.contentOffset.y - inset.top)
        }
        if stateView.viewportInsets != inset { stateView.viewportInsets = inset }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { render() }
    }
    func updateSearchResults(for searchController: UISearchController) { render() }
    func willPresentSearchController(_ searchController: UISearchController) { searchPresentationActive = true; render() }
    func didDismissSearchController(_ searchController: UISearchController) { searchPresentationActive = false; render() }
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
        let grouping = GroupingInput(contacts: all, query: query)
        if groupingInput != grouping {
            cachedGroups = mode == .contacts ? ContactDirectoryPresentation.sections(all, query: query)
                : [ContactSection(id: "records", contacts: all.filter { $0.matches(query) }.sorted {
                    $0.requestUpdatedAt == $1.requestUpdatedAt ? $0.peer.id < $1.peer.id : $0.requestUpdatedAt > $1.requestUpdatedAt
                })]
            groupingInput = grouping
        }
        let groups = cachedGroups
        let matches = groups.flatMap(\.contacts)
        let pending = runtime.contacts.filter { $0.requestState == "pending" && $0.requesterID != runtime.userID && !$0.isBlocked }.count
        let state = ChatListContentState.resolve(hasSnapshot: runtime.hasContactSnapshot, synchronization: runtime.synchronization,
            storageFailure: runtime.failure != nil, totalCount: all.count, matchCount: matches.count, searching: !query.isEmpty)
        let count = Localization.text("contacts.count", all.count)
        let footer = [mode == .contacts ? count : "", runtime.online ? "" : Localization.text("chat.live.offline")]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let appearance = locale.identifier + ":" + traitCollection.preferredContentSizeCategory.rawValue
            + ":\(traitCollection.userInterfaceStyle.rawValue):\(traitCollection.accessibilityContrast.rawValue):\(Localization.currentUIKitDirection.rawValue)"
        let next = Presentation(groups: groups, pending: pending, busy: busy, query: query,
            searching: isSearching, footer: footer, appearance: appearance, online: runtime.online, state: state)
        // 同步通知没有可见变化时，连背景提示和布局也保持不动；状态变化单独参与比较。
        guard presentation != next else { return }
        let previous = presentation
        if state == .content {
            if list.backgroundView != nil { list.backgroundView = nil }
        } else {
            if previous?.state != state || previous?.appearance != appearance {
                stateView.content.configure(state)
                if state == .empty {
                    let key = mode == .contacts ? "chat.live.emptyContacts" : mode == .requests ? "contacts.noRequests" : "contacts.noBlocked"
                    stateView.content.titleLabel.text = Localization.text(key)
                    stateView.content.detailLabel.text = mode == .contacts ? Localization.text("chat.live.addHelp") : ""
                }
                switch state {
                case .loading: stateView.content.titleLabel.text = Localization.text("contacts.loading")
                case .failed: stateView.content.titleLabel.text = Localization.text("contacts.loadFailed")
                case .noResults: stateView.content.titleLabel.text = Localization.text("contacts.noResults")
                default: break
                }
            }
            if list.backgroundView !== stateView { list.backgroundView = stateView }
        }
        let oldRows = Dictionary(uniqueKeysWithValues: (previous?.groups.flatMap(\.contacts) ?? []).map { ($0.peer.id, $0) })
        let changed = matches.filter {
            oldRows[$0.peer.id] != $0 || previous?.appearance != appearance
                || previous?.busy.contains($0.peer.id) != busy.contains($0.peer.id)
                || previous?.searching != isSearching || previous?.query.isEmpty != query.isEmpty
                || (previous?.online == false && runtime.online)
        }.map(\.peer.id)
        let surviving = Set(matches.map(\.peer.id))
        rowVersions = rowVersions.filter { surviving.contains($0.key) }
        for id in changed { rowVersions[id, default: 0] &+= 1 }
        let anchor = list.visibleCells.sorted { $0.frame.minY < $1.frame.minY }.compactMap { cell -> String? in
            guard let id = cell.accessibilityIdentifier, id.hasPrefix("contacts.peer.") else { return nil }
            let peer = String(id.dropFirst("contacts.peer.".count))
            return surviving.contains(peer) ? peer : nil
        }.first
        var transaction = ListTransaction.disabled
        if previous?.query == query, previous?.searching == isSearching,
           !list.isDragging, !list.isDecelerating, let anchor {
            transaction = transaction.scrollBehavior(.preserveVisiblePosition(of: .init(anchor)))
        }
        presentation = next
        let showEntry = mode == .contacts && query.isEmpty
        let showsIndex = showEntry && !isSearching && !groups.isEmpty
        adapter.apply(transaction: transaction, completion: { [weak self] _ in
            self?.setNeedsQuickLayout()
        }) {
            if showEntry {
                ListSection("entry") {
                    Row("requests", model: pending, cell: UICollectionViewListCell.self) { cell, count, _ in
                        var c = UIListContentConfiguration.cell()
                        c.text = Localization.text("chat.live.newFriends")
                        c.image = UIImage(systemName: "person.badge.plus"); c.imageProperties.tintColor = .systemBlue
                        c.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 20, trailing: 20)
                        cell.contentConfiguration = c; cell.accessories = []
                        cell.directionalLayoutMargins = .init(top: 0, leading: 20, bottom: 0, trailing: 20 + (showsIndex ? Self.indexWidth : 0))
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
                                cell.configure(contact, session: runtime.session, detail: requestDetail(contact, locale: locale), busy: busy.contains(contact.peer.id)) { [weak self] in self?.accept(contact) }
                            }.refreshID(rowVersions[contact.peer.id, default: 0])
                                .refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                                .onSelect { [weak self] contact, _ in self?.open(contact) }
                        } else {
                            Row(contact.peer.id, model: contact, cell: ContactDirectoryCell.self) { [weak self] cell, contact, _ in
                                self?.configure(cell, contact: contact, locale: locale)
                            }.refreshID(rowVersions[contact.peer.id, default: 0])
                                .refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                                .onSelect { [weak self] contact, _ in self?.open(contact) }
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
                            // 对称留出索引空间，使多行说明保持页面居中且不与索引重叠。
                            if showsIndex {
                                c.directionalLayoutMargins.leading += Self.indexWidth
                                c.directionalLayoutMargins.trailing += Self.indexWidth
                            }
                            cell.contentConfiguration = c
                            cell.accessibilityIdentifier = "contacts.footer"
                        }.layout(extendsBoundary: true)
                    }
                }.indexTitle(self.mode == .contacts && query.isEmpty && !self.isSearching ? group.id : nil)
                    .layout(Self.sectionLayout(group.id, header: false))
            }

        }
    }
    private func requestDetail(_ contact: ChatContact, locale: Locale) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.dateStyle = .medium; formatter.timeStyle = .none
        let date = formatter.string(from: Date(timeIntervalSince1970: Double(contact.requestUpdatedAt) / 1000))
        return [Localization.text(contact.requesterID == runtime.userID ? "chat.live.outgoing" : "chat.live.incoming"), contact.requestMessage, Localization.text("contacts.request." + contact.requestState), date].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private func configure(_ cell: ContactDirectoryCell, contact: ChatContact, locale: Locale) {
        var c = UIListContentConfiguration.subtitleCell()
        c.text = contact.peer.deleted == true ? Localization.text("account.deletedUser") : contact.displayName
        c.textProperties.numberOfLines = 0; c.secondaryTextProperties.numberOfLines = 0
        c.secondaryTextProperties.color = .secondaryLabel
        c.directionalLayoutMargins = .init(top: 12, leading: 20, bottom: 12, trailing: 20)
        if !contact.remark.isEmpty { c.secondaryText = contact.peer.nickname }
        cell.contentConfiguration = c; cell.accessories = []
        let showsIndex = mode == .contacts && !isSearching && search.searchBar.text?.isEmpty != false
        cell.directionalLayoutMargins = .init(top: 0, leading: 20, bottom: 0, trailing: 20 + (showsIndex ? Self.indexWidth : 0))
        let avatar = cell.avatar
        if let user = UUID(uuidString: contact.peer.id) {
            avatar.configure(session: runtime.session, user: user, asset: contact.peer.deleted == true ? nil : contact.peer.avatarID)
        } else { avatar.reset() }
        avatar.contentMode = .scaleAspectFit
        avatar.isAccessibilityElement = false
        cell.accessories.append(.customView(configuration: .init(customView: cell.avatarAccessoryView, placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true)))
        // 无 disclosure accessory 时，显式声明整行可点击，避免继承头像的图片语义。
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = "contacts.peer." + contact.peer.id
    }

    private static func sectionLayout(_ id: String, header: Bool) -> ListCustomSectionLayout<String> {
        ListCustomSectionLayout(id: id) { _, _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = .clear; config.headerMode = header ? .supplementary : .none
            config.separatorConfiguration.topSeparatorInsets.trailing = 0
            config.separatorConfiguration.bottomSeparatorInsets.trailing = 0
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }
    deinit {
        if let observation { let runtime = runtime; Task { @MainActor in runtime.remove(observation) } }
    }
}
/// 在固定尺寸的 accessory 容器中显示头像，使图片切换不改变整行的垂直对齐。
final class ContactDirectoryCell: UICollectionViewListCell {
    let avatar = AccountAvatarView()
    let avatarAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 系统只布局普通容器，避免直接使用图片 accessory 时受图片对齐信息影响。
        avatar.frame = avatarAccessoryView.bounds
        avatar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        avatarAccessoryView.addSubview(avatar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); avatar.reset() }
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
    private let avatar = AccountAvatarView()
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
                avatar.resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) { name.resizable(axis: .horizontal); detail.resizable(axis: .horizontal) }
                    .frame(maxWidth: .infinity)
            }
            if canAccept { accept.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 44) }
            separator.resizable(axis: .horizontal).frame(height: 0.5)
        }.padding(.horizontal, 20).padding(.top, 16)
    }
    override func prepareForReuse() { super.prepareForReuse(); avatar.reset(); accepted = nil }
    func configure(_ contact: ChatContact, session: SessionCoordinator? = nil, detail: String, busy: Bool, accepted: @escaping () -> Void) {
        name.text = contact.peer.deleted == true ? Localization.text("account.deletedUser") : contact.displayName
        self.detail.text = detail
        if let session, let user = UUID(uuidString: contact.peer.id) {
            avatar.configure(session: session, user: user, asset: contact.peer.deleted == true ? nil : contact.peer.avatarID)
        } else { avatar.reset() }
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

extension UIViewController {
    func showContactMessage(_ key: String) {
        let alert = UIAlertController(title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        present(alert, animated: true)
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("通讯录联系人行") {
    let cell = ContactDirectoryCell(frame: CGRect(x: 0, y: 0, width: 390, height: 72))
    var content = UIListContentConfiguration.subtitleCell()
    content.text = ConversationPreviewData.contact.displayName
    content.secondaryText = ConversationPreviewData.contact.peer.nickname
    cell.contentConfiguration = content
    cell.accessories = [.customView(configuration: .init(customView: cell.avatarAccessoryView, placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true))]
    return QuickLayoutHostingController { cell.resizable(axis: .horizontal).frame(height: 72) }
}
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
