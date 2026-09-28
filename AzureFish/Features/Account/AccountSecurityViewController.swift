import UIKit
import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import ListKit
import AppLocalization

/// 展示密码登录方式并进入需再次认证的账号安全操作。
final class AccountSecurityViewController: LocalizedQuickLayoutHostingController {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: collectionView)
    private var ready = false
    private var layoutWidth: CGFloat = 0

    private let session: SessionCoordinator
    private let runtime: ChatRuntime?
    init(session: SessionCoordinator, runtime: ChatRuntime? = nil) { self.session = session; self.runtime = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "account.design.security" }
    override var body: Layout { collectionView.resizable().safeAreaPadding(.all, 0) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "account.security.list"
        // QuickLayout 已消费导航与标签栏安全区域。
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.collectionViewLayout = adapter.makeCompositionalLayout()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        setContentScrollView(collectionView, for: .top)
        ready = true
        render()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = collectionView.bounds.width
        if width > 0, abs(width - layoutWidth) > 0.5 {
            layoutWidth = width
            collectionView.collectionViewLayout.invalidateLayout()
            render()
        }
    }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); render() }
    override func reloadLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        super.reloadLayoutDirection(direction)
        let semantic: UISemanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let changed = collectionView.semanticContentAttribute != semantic
        collectionView.semanticContentAttribute = semantic
        if ready, changed {
            // 原生列表装饰缓存属于 layout；方向变化时重建 layout，保留同一个列表与阅读位置。
            let offset = collectionView.contentOffset
            collectionView.setCollectionViewLayout(adapter.makeCompositionalLayout(), animated: false)
            collectionView.setContentOffset(offset, animated: false)
        } else {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { render() }
    }

    private func render() {
        guard ready else { return }
        let stackValue = collectionView.bounds.width < 378 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        adapter.apply(transaction: .disabled) {
            ListSection("methods") {
                Row("password", model: "account.security.password", cell: UICollectionViewListCell.self) { cell, key, _ in
                    Self.configure(cell, key: key, readOnly: true, stackValue: stackValue)
                }.selectionDisabled()
            }.header(UICollectionViewListCell.self, id: "methods-title") { header, _ in
                Self.configureHeader(header, key: "account.design.methods")
            }.footer(SettingsFooterView.self, id: "methods-help") { footer, _ in
                footer.configure(key: "account.security.methodsHelp")
            }.layout(Self.sectionLayout(id: "methods"))
            ListSection("operations") {
                ListKit.ForEach(["changePassword", "signOutAll"], id: \.self) { action in
                    Row(action, model: "account.design." + action, cell: UICollectionViewListCell.self) { cell, key, _ in
                        Self.configure(cell, key: key, stackValue: stackValue)
                    }
                    .onSelect { [weak self] key, _ in self?.open(key) }
                }
            }.header(UICollectionViewListCell.self, id: "operations-title") { header, _ in
                Self.configureHeader(header, key: "account.security.operations")
            }.layout(Self.sectionLayout(id: "operations"))
            ListSection("deletion") {
                Row("delete", model: "account.design.deleteAccount", cell: UICollectionViewListCell.self) { cell, key, _ in
                    Self.configure(cell, key: key, destructive: true, stackValue: stackValue)
                }
                .onSelect { [weak self] key, _ in self?.open(key) }
            }.layout(Self.sectionLayout(id: "deletion"))
        }
    }
    private static func configureHeader(_ header: UICollectionViewListCell, key: String) {
        var content = UIListContentConfiguration.groupedHeader()
        content.text = Localization.text(key)
        content.textProperties.numberOfLines = 0
        header.contentConfiguration = content
        header.backgroundConfiguration = .clear()
        header.accessibilityLabel = content.text
        header.accessibilityTraits = .header
    }
    private static func configure(_ cell: UICollectionViewListCell, key: String, readOnly: Bool = false, destructive: Bool = false, stackValue: Bool) {
        var content = stackValue ? UIListContentConfiguration.cell() : UIListContentConfiguration.valueCell()
        content.text = Localization.text(key)
        content.secondaryText = readOnly ? Localization.text("account.security.configured") : nil
        content.textProperties.numberOfLines = 0
        content.textProperties.color = destructive ? .systemRed : .label
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        cell.contentConfiguration = content
        cell.accessories = readOnly ? [] : [.disclosureIndicator()]
        cell.isAccessibilityElement = true
        cell.accessibilityIdentifier = key
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        cell.accessibilityTraits = readOnly ? .staticText : .button
    }
    private static func sectionLayout(id: String) -> ListCustomSectionLayout<String> {
        .custom(id: id) { _, _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            // 使用方向感知的固定边距，使各语言的分隔线与行内容对齐。
            configuration.separatorConfiguration.topSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            configuration.separatorConfiguration.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            let inset = max(24, (environment.container.effectiveContentSize.width - 600) / 2)
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: inset, bottom: 8, trailing: inset)
            return section
        }
    }
    private func open(_ key: String) {
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false) }
        let action: AccountSecurityAction = key.hasSuffix("changePassword") ? .changePassword : key.hasSuffix("signOutAll") ? .logoutAll : .deleteAccount
        navigationController?.pushViewController(AccountSecurityActionViewController(session: session, runtime: runtime, action: action), animated: true)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Security") { UINavigationController(rootViewController: AccountSecurityViewController(session: .configured())) }
@available(iOS 17.0, *)
#Preview("Security · large text") {
    let controller = AccountSecurityViewController(session: .configured())
    controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    return UINavigationController(rootViewController: controller)
}
@available(iOS 17.0, *)
#Preview("Security · RTL") {
    let controller = AccountSecurityViewController(session: .configured())
    controller.loadViewIfNeeded()
    controller.reloadLayoutDirection(.rightToLeft)
    return UINavigationController(rootViewController: controller)
}
#endif
