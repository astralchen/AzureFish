import UIKit
import ListKit
import QuickLayout
import QuickLayoutKit

/// 个人中心的 ListKit 分组菜单，使用原生列表附件处理箭头、分隔线和 RTL。
final class ProfileMenuView: QuickLayoutView {
    private let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: collectionView)
    private var sizeObservation: NSKeyValueObservation?
    private var contentHeight: CGFloat = 320
    var didSelect: ((String) -> Void)?
    var heightDidChange: (() -> Void)?
    var isReloading = false { didSet { reloadContent() } }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        // 整页由外层滚动容器管理，菜单高度跟随实际自适应 Cell 测量结果。
        collectionView.isScrollEnabled = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.collectionViewLayout = adapter.makeCompositionalLayout()
        sizeObservation = collectionView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = ceil(self.collectionView.collectionViewLayout.collectionViewContentSize.height)
                guard height > 0, abs(height - self.contentHeight) > 0.5 else { return }
                self.contentHeight = height
                self.invalidateIntrinsicContentSize()
                self.setNeedsQuickLayout()
                self.heightDidChange?()
            }
        }
        reloadContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var body: Layout {
        collectionView.resizable().frame(height: contentHeight)
    }

    /// 刷新现有列表身份对应的语言与处理中状态，不重建控制器或业务会话。
    func reloadContent() {
        collectionView.semanticContentAttribute = Localization.currentUIKitDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        adapter.apply(transaction: .disabled) {
            ListSection("navigation") {
                ListKit.ForEach(["account.design.editProfile", "account.design.security", "account.design.settings"], id: \.self) { key in
                    Row(key, model: key, cell: UICollectionViewListCell.self) { cell, key, _ in
                        Self.configure(cell, key: key, disclosure: true)
                    }.onSelect { [weak self] key, _ in self?.select(key) }
                }
            }.layout(Self.sectionLayout(id: "navigation", top: 0))
            ListSection("refresh") {
                Row("account.design.reload", model: isReloading, cell: UICollectionViewListCell.self) { cell, busy, _ in
                    Self.configure(cell, key: "account.design.reload", disclosure: false)
                    cell.isUserInteractionEnabled = !busy
                    if busy {
                        let progress = UIActivityIndicatorView(style: .medium)
                        progress.startAnimating()
                        cell.accessories = [.customView(configuration: .init(customView: progress, placement: .trailing()))]
                        cell.accessibilityValue = Localization.text("account.design.loading")
                    }
                }.onSelect { [weak self] _, _ in self?.select("account.design.reload") }
            }.layout(Self.sectionLayout(id: "refresh", top: 16))
            ListSection("logout") {
                Row("account.design.signOut", model: "account.design.signOut", cell: UICollectionViewListCell.self) { cell, key, _ in
                    Self.configure(cell, key: key, disclosure: false)
                }.onSelect { [weak self] key, _ in self?.select(key) }
            }.layout(Self.sectionLayout(id: "logout", top: 24))
        }
    }

    private static func sectionLayout(id: String, top: CGFloat) -> ListCustomSectionLayout<String> {
        .custom(id: id) { _, _, environment in
            let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            // 宿主已施加页面边距，避免系统 insetGrouped 再叠加一层水平缩进。
            section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: 0, trailing: 0)
            return section
        }
    }
    private static func configure(_ cell: UICollectionViewListCell, key: String, disclosure: Bool) {
        var content = UIListContentConfiguration.cell()
        content.text = Localization.text(key)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.color = disclosure ? .label : (key == "account.design.signOut" ? .systemRed : .systemBlue)
        content.textProperties.numberOfLines = 0
        content.textProperties.alignment = disclosure ? .natural : .center
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        cell.contentConfiguration = content
        cell.accessories = disclosure ? [.disclosureIndicator()] : []
        cell.isUserInteractionEnabled = true
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = key
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = nil
    }
    private func select(_ key: String) {
        if key == "account.design.reload", isReloading { return }
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: true) }
        didSelect?(key)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Profile ListKit menu") { QuickLayoutHostingController { ProfileMenuView().padding(24) } }
#endif
