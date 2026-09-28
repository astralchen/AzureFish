import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

struct LiveChatRow: Sendable, Equatable {
    let id: String
    let title: String
    var subtitle: String = ""
    var symbol: String = "person.crop.circle.fill"
    var badge: String = ""
    var markers: [String] = []
    var highlight: String? = nil
    var isPinned = false
    var manuallyUnread = false
}
/// 通讯录、会话和成员选择共享的原生列表，实体身份不随语言改变。
class LiveChatListController: LocalizedQuickLayoutHostingController, UISearchResultsUpdating {
    let runtime: ChatRuntime
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    var rows: [LiveChatRow] = [] { didSet { renderRows() } }
    var selected: ((String) -> Void)?
    private var observation: UUID?
    private let search = UISearchController(searchResultsController: nil)
    var query: String { search.searchBar.text ?? "" }
    var showsSeparators: Bool { true }
    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        list.backgroundColor = .clear
        list.contentInsetAdjustmentBehavior = .automatic
        list.alwaysBounceVertical = true
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        setContentScrollView(list, for: .top)
        navigationItem.searchController = search
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.hidesSearchBarWhenScrolling = false
        let refresh = UIRefreshControl()
        refresh.addAction(
            UIAction { [weak self] _ in
                Task { [weak self, weak refresh] in
                    await self?.runtime.refreshAndWait()
                    refresh?.endRefreshing()
                }
            }, for: .valueChanged)
        list.refreshControl = refresh
        observation = runtime.observe { [weak self] in self?.reloadRows() }
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        search.searchBar.placeholder = Localization.text("chat.live.search")
        reloadRows()
        // 用户标题和正文可能不随语言变化，仍需更新“已置顶”和手动未读的无障碍说明。
        adapter.reconfigureRows(forRowIDs: rows.map(\.id), transaction: .disabled, completion: nil)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            adapter.reconfigureRows(forRowIDs: rows.map(\.id), layout: .invalidate,
                transaction: .disabled, completion: nil)
        }
    }
    func updateSearchResults(for searchController: UISearchController) { reloadRows() }
    func reloadRows() { renderRows() }
    private func renderRows() {
        guard isViewLoaded else { return }
        let values = rows
        adapter.apply(transaction: .disabled) {
            ListSection("content") {
                ListKit.ForEach(values, id: \.id) { value in
                    Row(value.id, model: value, cell: UICollectionViewListCell.self) { cell, value, _ in
                        var c = UIListContentConfiguration.subtitleCell()
                        c.text = value.title
                        if let highlight = value.highlight, !highlight.isEmpty,
                           let range = value.title.range(of: highlight, options: .caseInsensitive) {
                            let text = NSMutableAttributedString(string: value.title)
                            text.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), range: NSRange(range, in: value.title))
                            c.attributedText = text
                        }
                        c.secondaryText = value.subtitle
                        c.textProperties.font = .preferredFont(forTextStyle: .body)
                        c.textProperties.numberOfLines = 0
                        c.secondaryTextProperties.numberOfLines = 2
                        c.secondaryTextProperties.color = .secondaryLabel
                        let accessibilitySize = cell.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                        c.image = accessibilitySize ? nil : UIImage(systemName: value.symbol)
                        c.imageProperties.tintColor = .systemBlue
                        cell.contentConfiguration = c
                        var background = UIBackgroundConfiguration.listPlainCell()
                        background.backgroundColor = value.isPinned ? .secondarySystemBackground : .systemBackground
                        cell.backgroundConfiguration = background
                        cell.accessories = [.disclosureIndicator()]
                        if accessibilitySize {
                            // 原生内容视图的大字体环绕在混合 RTL 文本中可能与头像重叠，改由 accessory 保留独立宽度。
                            let avatar = UIImageView(image: UIImage(systemName: value.symbol))
                            avatar.tintColor = .systemBlue
                            avatar.contentMode = .scaleAspectFit
                            avatar.frame.size = CGSize(width: 36, height: 36)
                            avatar.isAccessibilityElement = false
                            cell.accessories.append(.customView(configuration: .init(customView: avatar,
                                placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true)))
                        }
                        for marker in value.markers {
                            let image = UIImageView(image: UIImage(systemName: marker))
                            image.tintColor = .secondaryLabel
                            image.accessibilityLabel = Localization.text(marker == "pin.fill" ? "chat.details.pinned" : "chat.details.muted")
                            cell.accessories.insert(.customView(configuration: .init(customView: image, placement: .trailing())), at: 0)
                        }
                        if !value.badge.isEmpty || value.manuallyUnread {
                            let badge = UnreadCountBadgeView(text: value.badge, dot: value.badge.isEmpty)
                            // 保留容器尺寸，由系统按整行中心排列；内部文字不参与 accessory 基线对齐。
                            cell.accessories.insert(.customView(configuration: .init(
                                customView: badge, placement: .trailing(),
                                reservedLayoutWidth: .actual, maintainsFixedSize: true)), at: 0)
                        }
                        let status = (value.isPinned ? [Localization.text("chat.details.pinned")] : [])
                            + (value.manuallyUnread ? [Localization.text("chat.list.manuallyUnread")] : [])
                        cell.accessibilityLabel = ([value.title, value.subtitle, value.badge] + status + value.markers.map { Localization.text($0 == "pin.fill" ? "chat.details.pinned" : "chat.details.muted") }).filter { !$0.isEmpty }
                            .joined(separator: ", ")
                        cell.accessibilityIdentifier = "chat.row." + value.id
                    }.onSelect { [weak self] _, _ in self?.selected?(value.id) }
                }
            }.layout(
                ListCustomSectionLayout(id: "content") { [weak self] _, _, environment in
                    var config = UICollectionLayoutListConfiguration(appearance: .plain)
                    config.backgroundColor = .clear
                    config.showsSeparators = self?.showsSeparators ?? true
                    config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                        guard let self, let id = adapter.rowIdentifier(at: indexPath, as: String.self) else { return nil }
                        return trailingActions(for: id)
                    }
                    return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
                })
        }
    }
    func trailingActions(for id: String) -> UISwipeActionsConfiguration? { nil }
    func showError(_ error: Error) {
        let key: String
        if case APIClientError.service(let failure) = error {
            switch failure.code {
            case .friendRequired: key = "chat.live.friendRequired"
            case .contactVersionConflict, .contactActionUnavailable, .conversationVersionConflict:
                key = "chat.live.changed"
            case .userNotFound: key = "chat.live.notFound"
            case .selfContact: key = "chat.live.selfContact"
            case .rateLimited: key = "chat.live.rateLimited"
            default: key = "chat.live.failed"
            }
        } else {
            key = "chat.live.failed"
        }
        let alert = UIAlertController(title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        present(alert, animated: true)
    }
    deinit {
        if let observation {
            let runtime = runtime
            Task { @MainActor in runtime.remove(observation) }
        }
    }
}
final class ContactsViewController: LiveChatListController {
    override var localizedTitleKey: String? { "chat.live.contacts" }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "person.badge.plus"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                navigationController?.pushViewController(AddFriendViewController(runtime: runtime), animated: true)
            })
        selected = { [weak self] id in
            guard let self else { return }
            if id == "requests" {
                navigationController?.pushViewController(FriendRequestsViewController(runtime: runtime), animated: true)
            } else if let contact = runtime.contacts.first(where: { $0.peer.id == id }) {
                navigationController?.pushViewController(
                    FriendViewController(runtime: runtime, contact: contact), animated: true)
            }
        }
    }
    override func reloadRows() {
        let pending = runtime.contacts.filter { $0.state == "pending" && $0.requesterID != runtime.userID }.count
        tabBarItem.badgeValue = pending > 99 ? "99+" : pending > 0 ? String(pending) : nil
        tabBarItem.badgeColor = .systemRed
        navigationController?.tabBarItem.badgeValue = tabBarItem.badgeValue
        navigationController?.tabBarItem.badgeColor = .systemRed
        let matches = runtime.contacts.filter {
            $0.state == "friend" && (query.isEmpty || $0.peer.nickname.localizedStandardContains(query))
        }.sorted { $0.peer.nickname.localizedStandardCompare($1.peer.nickname) == .orderedAscending }
        rows =
            [
                LiveChatRow(
                    id: "requests", title: Localization.text("chat.live.newFriends"),
                    subtitle: pending > 0 ? String(pending) + " · " + Localization.text("chat.live.pending") : "",
                    symbol: "person.badge.plus", badge: pending > 99 ? "99+" : pending > 0 ? String(pending) : "")
            ] + matches.map { LiveChatRow(id: $0.peer.id, title: $0.peer.nickname) }
        if matches.isEmpty {
            rows.append(
                LiveChatRow(
                    id: "empty", title: Localization.text("chat.live.emptyContacts"),
                    subtitle: Localization.text(runtime.online ? "chat.live.addHelp" : "chat.live.offline"),
                    symbol: "person.2"))
        }
    }
}
final class FriendRequestsViewController: LiveChatListController {
    override var localizedTitleKey: String? { "chat.live.newFriends" }
    override func viewDidLoad() {
        super.viewDidLoad()
        selected = { [weak self] id in
            guard let self, let c = runtime.contacts.first(where: { $0.peer.id == id }) else { return }
            navigationController?.pushViewController(FriendViewController(runtime: runtime, contact: c), animated: true)
        }
    }
    override func reloadRows() {
        rows = runtime.contacts.filter { $0.state != "friend" && $0.state != "deleted" }.sorted {
            $0.updatedAt > $1.updatedAt
        }.map {
            LiveChatRow(
                id: $0.peer.id, title: $0.peer.nickname,
                subtitle: Localization.text(
                    $0.requesterID == runtime.userID ? "chat.live.outgoing" : "chat.live.incoming") + " · "
                    + Localization.text("chat.live." + $0.state))
        }
    }
}
final class ConversationListViewController: LiveChatListController {
    var openConversation: ((ChatConversation) -> Void)?
    private let stateView = ChatListStateView(frame: .zero)
    private var renderGeneration = UUID()
    private var keyboardFrame: CGRect?
    override var localizedTitleKey: String? { "account.design.chat" }
    override var showsSeparators: Bool { false }
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad()
        stateView.content.retry = { [weak self] in self?.runtime.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        navigationController?.navigationBar.prefersLargeTitles = true
        selected = { [weak self] id in
            guard let self, let c = runtime.conversations.first(where: { $0.id == id }) else { return }
            open(c)
        }
        menu()
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
            // 浮动键盘不把整个列表底部变成额外留白。
            if !intersection.isNull, intersection.maxY >= list.bounds.maxY - 1,
                intersection.width >= list.bounds.width * 0.9 { overlap = intersection.height }
        }
        let systemBottom = max(0, list.adjustedContentInset.bottom - list.contentInset.bottom)
        let bottom = max(0, overlap - systemBottom)
        if abs(list.contentInset.bottom - bottom) > 0.5 { list.contentInset.bottom = bottom }
        stateView.viewportInsets = list.adjustedContentInset
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        if isViewLoaded { menu() }
    }
    private func menu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), primaryAction: nil,
            menu: UIMenu(children: [
                UIAction(title: Localization.text("chat.live.newChat"), image: UIImage(systemName: "square.and.pencil"))
                { [weak self] _ in self?.choose(group: false) },
                UIAction(title: Localization.text("chat.live.newGroup"), image: UIImage(systemName: "person.3")) {
                    [weak self] _ in self?.choose(group: true)
                },
            ]))
    }
    private func choose(group: Bool) {
        let chooser = FriendPickerViewController(runtime: runtime, group: group)
        chooser.completed = { [weak self] c in self?.open(c) }
        navigationController?.pushViewController(chooser, animated: true)
    }
    func open(_ conversation: ChatConversation) {
        if let openConversation {
            openConversation(conversation)
        } else {
            navigationController?.pushViewController(
                ConversationPageFactory.make(runtime: runtime, conversation: conversation), animated: true)
        }
    }
    override func trailingActions(for id: String) -> UISwipeActionsConfiguration? {
        guard runtime.visibleSortedConversations.contains(where: { $0.id == id }) else { return nil }
        let unread = UIContextualAction(style: .normal, title: Localization.text("chat.list.markUnread")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                do { try await runtime.markConversationUnread(id); completion(true) }
                catch { completion(false); showError(error) }
            }
        }
        unread.backgroundColor = .systemBlue
        let hide = UIContextualAction(style: .normal, title: Localization.text("chat.list.hide")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                do { try await runtime.hideConversation(id); completion(true) }
                catch { completion(false); showError(error) }
            }
        }
        hide.backgroundColor = .systemGray
        let delete = UIContextualAction(style: .destructive, title: Localization.text("chat.list.delete")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            // 先结束滑动状态，确认取消时不会留下已执行的视觉反馈。
            completion(false)
            let alert = UIAlertController(title: Localization.text("chat.list.deleteTitle"),
                message: Localization.text("chat.list.deleteHelp"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: Localization.text("chat.list.delete"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                Task {
                    do { try await runtime.hideConversation(id, deleting: true) }
                    catch { showError(error) }
                }
            })
            present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete, hide, unread])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    override func reloadRows() {
        let generation = UUID()
        renderGeneration = generation
        let matches = runtime.visibleSortedConversations.filter {
            query.isEmpty || runtime.title($0).localizedStandardContains(query)
        }
        rows = matches.map {
            LiveChatRow(
                id: $0.id, title: runtime.title($0),
                subtitle: $0.closed
                    ? Localization.text("chat.live.closed")
                    : ($0.readState.unread > 0
                        ? String($0.readState.unread) + " · " + Localization.text("chat.live.unread") : ""),
                symbol: $0.kind == "group" ? "person.3.fill" : "person.crop.circle.fill",
                badge: $0.readState.unread > 99 ? "99+" : $0.readState.unread > 0 ? String($0.readState.unread) : "",
                markers: runtime.preference($0.id).isMuted ? ["bell.slash.fill"] : [],
                isPinned: runtime.preference($0.id).isPinned,
                manuallyUnread: runtime.listStates[$0.id]?.manuallyUnread == true)
        }
        let state = ChatListContentState.resolve(
            hasSnapshot: runtime.hasSnapshot, synchronization: runtime.synchronization,
            storageFailure: runtime.failure != nil, totalCount: runtime.visibleSortedConversations.count,
            matchCount: matches.count, searching: !query.isEmpty)
        if state == .storageFailure { rows = [] }
        if state == .content {
            list.backgroundView = nil
        } else {
            stateView.content.configure(state)
            list.backgroundView = stateView
        }
        let hasCachedContent = runtime.hasSnapshot || !runtime.conversations.isEmpty
        navigationItem.prompt = runtime.failure == nil && hasCachedContent
            ? (runtime.synchronization == .failed ? Localization.text("chat.list.syncFailed")
               : runtime.synchronization == .syncing ? Localization.text("chat.list.syncing") : nil)
            : nil
        updateViewport()
        Task { [weak self] in
            guard let self, let store = runtime.engine?.store else { return }
            var values = rows
            for i in values.indices {
                if let message = try? await store.latestVisibleMessage(values[i].id) {
                    values[i].subtitle =
                        message.revoked
                        ? Localization.text("chat.live.revoked")
                        : message.kind == "system" ? ChatSystemNotice.text(message, userID: runtime.userID)
                        : message.kind == "text" ? message.text : Localization.text("chat.live." + message.kind)
                }
            }
            guard renderGeneration == generation else { return }
            rows = values
        }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
#if DEBUG
    @available(iOS 17.0, *)
    #Preview("通讯录 · 原生列表") { ContactsViewController(runtime: ChatRuntime(session: .configured())) }
@available(iOS 17.0, *)
#Preview("会话列表 · 置顶与未读") {
    let controller = LiveChatListController(runtime: ChatRuntime(session: .configured()))
    controller.loadViewIfNeeded()
    controller.rows = [
        LiveChatRow(id: "pinned", title: "周末去海边", subtitle: "我们周六见", isPinned: true, manuallyUnread: true),
        LiveChatRow(id: "ordinary", title: "林沐", subtitle: "照片", badge: "3")
    ]
    return controller
}
#endif
