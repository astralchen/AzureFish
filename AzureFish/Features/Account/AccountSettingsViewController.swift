import UIKit
import QuickLayoutKit
import QuickLayout
import ListKit
import AppLocalization

/// 使用独立 ListKit 列表展示安装偏好；选择后保持当前导航与会话。
final class AccountSettingsViewController: LocalizedQuickLayoutHostingController {
    enum Page { case overview, appearance, language, privacy }
    private let runtime: ChatRuntime?
    private let page: Page
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: collectionView)
    private var ready = false
    private var layoutWidth: CGFloat = 0

    init(page: Page = .overview, runtime: ChatRuntime? = nil) { self.runtime = runtime; self.page = page; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? {
        switch page {
        case .overview: "account.design.settings"
        case .appearance: "account.design.appearance"
        case .language: "account.design.language"
        case .privacy: "contacts.privacy"
        }
    }
    override var body: Layout { collectionView.resizable().safeAreaPadding(.all, 0) }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.accessibilityIdentifier = "account.settings.list"
        // QuickLayout 已消费页面安全区域；不再由列表添加导航与标签栏 inset。
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.collectionViewLayout = adapter.makeCompositionalLayout()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = page == .overview ? .always : .never
        setContentScrollView(collectionView, for: .top)
        NotificationCenter.default.addObserver(self, selector: #selector(preferenceChanged), name: AppearancePreference.didChangeNotification, object: nil)
        ready = true
        reloadLocalizedContent()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); render() }
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
        collectionView.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        collectionView.collectionViewLayout.invalidateLayout()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { render() }
    }
    @objc private func preferenceChanged() { render() }

    private func render() {
        guard ready else { return }
        switch page {
        case .overview:
            let stackValue = collectionView.bounds.width < 378 || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            let appearance = Localization.text("account.design.\(AppearancePreference.choice.rawValue)")
            let language = Localization.localizationController.followsSystemLocale
                ? Localization.text("language.follow.system") : Localization.localizationController.currentLocale.nativeDisplayName
            adapter.apply(transaction: .disabled) {
                if runtime != nil {
                    ListSection("privacy") {
                        Row("privacy", model: "contacts.privacy", cell: UICollectionViewListCell.self) { cell, key, _ in
                            Self.configure(cell, id: key, title: Localization.text(key), value: "", stackValue: false)
                        }.onSelect { [weak self] _, _ in self?.open(.privacy) }
                    }.layout(Self.sectionLayout(id: "privacy"))
                }
                ListSection("appearance") {
                    Row("account.design.appearance", model: appearance, cell: UICollectionViewListCell.self) { cell, value, _ in
                        Self.configure(cell, id: "account.design.appearance", title: Localization.text("account.design.appearance"), value: value, stackValue: stackValue)
                    }.onSelect { [weak self] _, _ in self?.open(.appearance) }
                }.footer(SettingsFooterView.self, id: "appearance-help") { footer, _ in
                    footer.configure(key: "account.design.appearanceHelp")
                }.boundarySupplementaryLayout(kind: UICollectionView.elementKindSectionFooter, alignment: .bottom, extendsBoundary: true)
                    .layout(Self.sectionLayout(id: "appearance"))
                ListSection("language") {
                    Row("account.design.language", model: language, cell: UICollectionViewListCell.self) { cell, value, _ in
                        Self.configure(cell, id: "account.design.language", title: Localization.text("account.design.language"), value: value, stackValue: stackValue)
                    }.onSelect { [weak self] _, _ in self?.open(.language) }
                }.footer(SettingsFooterView.self, id: "language-help") { footer, _ in
                    footer.configure(key: "account.design.languageHelp")
                }.boundarySupplementaryLayout(kind: UICollectionView.elementKindSectionFooter, alignment: .bottom, extendsBoundary: true)
                    .layout(Self.sectionLayout(id: "language"))
            }
        case .privacy:
            adapter.apply(transaction: .disabled) {
                ListSection("blacklist") {
                    Row("blacklist", model: "contacts.blacklist", cell: UICollectionViewListCell.self) { cell, key, _ in
                        Self.configure(cell, id: key, title: Localization.text(key), value: "", stackValue: false)
                    }.onSelect { [weak self] _, _ in
                        guard let self, let runtime else { return }
                        navigationController?.pushViewController(BlockedContactsViewController(runtime: runtime), animated: true)
                    }
                }.layout(Self.sectionLayout(id: "blacklist"))
            }
        case .appearance:
            adapter.apply(transaction: .disabled) {
                ListSection("appearance-options") {
                    ListKit.ForEach(AppearancePreference.Choice.allCases, id: \.rawValue) { choice in
                        Row(choice.rawValue, model: choice.rawValue, cell: UICollectionViewListCell.self) { cell, value, _ in
                            Self.configure(cell, id: "account.appearance." + value, title: Localization.text("account.design." + value), selected: AppearancePreference.choice.rawValue == value)
                        }.onSelect { [weak self] _, _ in
                            self?.clearSelection()
                            AppearancePreference.select(choice)
                        }
                    }
                }.footer(SettingsFooterView.self, id: "appearance-help") { footer, _ in
                    footer.configure(key: "account.design.appearanceHelp")
                }.boundarySupplementaryLayout(kind: UICollectionView.elementKindSectionFooter, alignment: .bottom, extendsBoundary: true)
                    .layout(Self.sectionLayout(id: "appearance-options"))
            }
        case .language:
            let controller = Localization.localizationController
            let locales = ["zh-Hans", "zh-Hant", "en", "ar"].compactMap { identifier in
                controller.supportedLocales.first { $0.identifier == identifier || $0.identifier.hasPrefix(identifier + "-") }
            }
            adapter.apply(transaction: .disabled) {
                ListSection("language-options") {
                    Row("system", model: controller.followsSystemLocale, cell: UICollectionViewListCell.self) { cell, selected, _ in
                        Self.configure(cell, id: "account.language.system", title: Localization.text("language.follow.system"), selected: selected)
                    }.onSelect { [weak self] _, _ in
                        self?.clearSelection()
                        Localization.setLocale(identifier: LocalizationController.followSystemLocaleIdentifier)
                    }
                    ListKit.ForEach(locales, id: \.identifier) { locale in
                        Row(locale.identifier, model: locale.identifier, cell: UICollectionViewListCell.self) { cell, identifier, _ in
                            Self.configure(cell, id: "account.language." + identifier, title: locale.nativeDisplayName,
                                selected: !controller.followsSystemLocale && controller.currentLocale.identifier == identifier)
                        }.onSelect { [weak self] identifier, _ in
                            self?.clearSelection()
                            Localization.setLocale(identifier: identifier)
                        }
                    }
                }.footer(SettingsFooterView.self, id: "language-help") { footer, _ in
                    footer.configure(key: "account.design.languageHelp")
                }.boundarySupplementaryLayout(kind: UICollectionView.elementKindSectionFooter, alignment: .bottom, extendsBoundary: true)
                    .layout(Self.sectionLayout(id: "language-options"))
            }
        }
    }
    private func open(_ page: Page) {
        clearSelection()
        navigationController?.pushViewController(AccountSettingsViewController(page: page, runtime: runtime), animated: true)
    }
    private func clearSelection() {
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false) }
    }
    private static func sectionLayout(id: String) -> ListCustomSectionLayout<String> {
        .custom(id: id) { _, _, environment in
            let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            let inset = max(24, (environment.container.effectiveContentSize.width - 600) / 2)
            section.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: inset, bottom: 8, trailing: inset)
            return section
        }
    }
    private static func configure(_ cell: UICollectionViewListCell, id: String, title: String, value: String? = nil, selected: Bool? = nil, stackValue: Bool = false) {
        // 双行 valueCell 保留原生语义；窄屏及大字体使用纵向排列，避免与箭头争夺宽度。
        var content = value == nil || stackValue
            ? UIListContentConfiguration.cell() : UIListContentConfiguration.valueCell()
        content.text = title
        content.secondaryText = value
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        cell.contentConfiguration = content
        cell.accessories = selected.map { $0 ? [.checkmark()] : [] } ?? [.disclosureIndicator()]
        cell.accessibilityIdentifier = id
        cell.accessibilityLabel = title
        cell.accessibilityValue = value
        cell.accessibilityTraits = selected == true ? [.button, .selected] : [.button]
    }
}

/// 会话恢复页不显示旧账号内容；原数据不可读时允许重试和查看恢复说明。
final class AccountRecoveryViewController: AccountScreen {
    private let session: SessionCoordinator
    private let feedback = UILabel()
    init(session: SessionCoordinator) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .body); feedback.adjustsFontForContentSizeCategory = true
        content = [label("account.brand", style: .title1), feedback]
        actions = [button("account.design.retry", primary: true) { [weak self] in
            guard let self else { return }; Task { await self.session.restore(); self.reloadLocalizedContent() }
        }, button("account.design.recovery") { [weak self] in self?.showMessage("account.design.recoveryHelp") },
        button("account.design.localLogout", destructive: true) { [weak self] in self?.confirmLocalLogout() }]
        reloadLocalizedContent()
    }
    private func confirmLocalLogout() {
        let alert = UIAlertController(title: Localization.text("account.design.localLogout"),
            message: Localization.text("account.design.logoutOffline"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.localLogout"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do { try await self.session.logout(localOnly: true) }
                catch { self.showMessage(AccountFailure.key(for: error)) }
            }
        })
        present(alert, animated: true)
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        feedback.text = Localization.text(session.noticeKey ?? "account.design.loading")
        actions.forEach { $0.isHidden = session.phase == .restoring }
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Settings") { UINavigationController(rootViewController: AccountSettingsViewController()) }
@available(iOS 17.0, *)
#Preview("Appearance options") { UINavigationController(rootViewController: AccountSettingsViewController(page: .appearance)) }
@available(iOS 17.0, *)
#Preview("Language options · large text") {
    let controller = AccountSettingsViewController(page: .language)
    controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    return UINavigationController(rootViewController: controller)
}
@available(iOS 17.0, *)
#Preview("Settings · RTL") {
    let controller = AccountSettingsViewController()
    controller.loadViewIfNeeded()
    controller.reloadLayoutDirection(.rightToLeft)
    return UINavigationController(rootViewController: controller)
}
@available(iOS 17.0, *)
#Preview("Recovery") { AccountRecoveryViewController(session: .configured()) }
#endif
