import AppLocalization
import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 通讯录、会话和成员选择共享的原生列表，实体身份不随语言改变。
class LiveChatListController: LocalizedQuickLayoutHostingController, UISearchResultsUpdating {
    let runtime: ChatRuntime
    let connectionLabel = UILabel()
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    private var renderedRows: [LiveChatRow]?
    private var renderedReadOnly: Bool?
    var rows: [LiveChatRow] = [] { didSet { renderRows() } }
    var selected: ((String) -> Void)?
    private var observation: UUID?
    private let search = UISearchController(searchResultsController: nil)
    var query: String { search.searchBar.text ?? "" }
    var showsSeparators: Bool { true }
    var usesConversationLayout: Bool { false }
    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(spacing: 0) {
            if runtime.session.readOnly { connectionLabel.resizable(axis: .horizontal).padding(16) }
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        connectionLabel.font = .preferredFont(forTextStyle: .footnote)
        connectionLabel.adjustsFontForContentSizeCategory = true
        connectionLabel.numberOfLines = 0
        connectionLabel.textColor = .secondaryLabel
        connectionLabel.accessibilityIdentifier = "account.connection.status"
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
        let connectionText = Localization.text(runtime.session.connectivity == .checking ? "account.connection.checking" : "account.connection.offline")
        if connectionLabel.text != connectionText || renderedReadOnly != runtime.session.readOnly {
            connectionLabel.text = connectionText
            renderedReadOnly = runtime.session.readOnly
            setNeedsQuickLayout()
        }
        guard renderedRows != rows else { return }
        renderedRows = rows
        let values = rows
        adapter.apply(transaction: .disabled) {
            ListSection("content") {
                ListKit.ForEach(values, id: \.id) { value in
                    Row(value.id, model: value, cell: UICollectionViewListCell.self) { cell, value, _ in
                        let status = (value.isPinned ? [Localization.text("chat.details.pinned")] : [])
                            + (value.manuallyUnread ? [Localization.text("chat.list.manuallyUnread")] : [])
                        cell.accessibilityLabel = ([value.title, value.subtitle, value.timeAccessibilityText, value.badge] + status + value.markers.map { Localization.text($0 == "pin.fill" ? "chat.details.pinned" : "chat.details.muted") }).filter { !$0.isEmpty }
                            .joined(separator: ", ")
                        cell.accessibilityIdentifier = "chat.row." + value.id
                        var background = UIBackgroundConfiguration.listPlainCell()
                        background.backgroundColor = value.isPinned ? .secondarySystemBackground : .systemBackground
                        cell.backgroundConfiguration = background
                        if self.usesConversationLayout {
                            cell.contentConfiguration = ConversationRowConfiguration(row: value, session: self.runtime.session)
                            cell.accessories = []
                            return
                        }
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
                        if value.isDraft {
                            let text = NSMutableAttributedString(string: value.subtitle)
                            let marker = Localization.text("chat.list.draftMarker")
                            if let range = value.subtitle.range(of: marker) {
                                text.addAttribute(.foregroundColor, value: UIColor.systemRed,
                                                  range: NSRange(range, in: value.subtitle))
                            }
                            c.secondaryAttributedText = text
                        }
                        // 控制器的字号已更新时，复用单元格可能尚未收到新的 traits。
                        let accessibilitySize = self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
                        c.image = accessibilitySize || value.avatarUser != nil ? nil : UIImage(systemName: value.symbol)
                        c.imageProperties.tintColor = .systemBlue
                        cell.contentConfiguration = c
                        cell.accessories = [.disclosureIndicator()]
                        if let user = value.avatarUser.flatMap(UUID.init(uuidString:)) {
                            let avatar = AccountAvatarView()
                            avatar.configure(session: self.runtime.session, user: user, asset: value.avatarAsset)
                            avatar.frame.size = CGSize(width: 36, height: 36)
                            cell.accessories.append(.customView(configuration: .init(customView: avatar,
                                placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true)))
                        } else if accessibilitySize {
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

#if DEBUG
@available(iOS 17.0, *)
#Preview("会话列表 · 置顶与未读") {
    let controller = LiveChatListController(runtime: ChatRuntime(session: .configured()))
    controller.loadViewIfNeeded()
    controller.rows = [
        LiveChatRow(id: "pinned", title: "周末去海边", subtitle: "[草稿] 我们周六见", isPinned: true, manuallyUnread: true, isDraft: true, timeText: "20:10"),
        LiveChatRow(id: "ordinary", title: "林沐", subtitle: "照片", badge: "3", timeText: "9/28")
    ]
    return controller
}
#endif
