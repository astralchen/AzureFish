import AppLocalization
import AzureFishAPI
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 评论列表的 ListKit 映射与阅读位置；输入区遮挡只改变内容 inset。
final class ShortVideoCommentsView: QuickLayoutView {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    var deleteRequested: ((VideoComment) -> Void)?
    var retryRequested: (() -> Void)?
    private lazy var adapter = CollectionListAdapter<String>(collectionView: collectionView)
    private var previousInsets = UIEdgeInsets.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        collectionView.backgroundColor = .clear
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.collectionViewLayout = adapter.makeCompositionalLayout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout { collectionView.resizable() }
    func applyLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        semanticContentAttribute = direction.appLayoutDirection.semanticContentAttribute
        collectionView.applyLocalization(Localization.layoutDirectionUpdate(direction), preservingVisibleItem: true,
            rebuildingLayoutWith: { [unowned self] in adapter.makeCompositionalLayout() })
        setNeedsQuickLayout()
    }
    func updateViewportInsets(_ insets: UIEdgeInsets) {
        guard previousInsets != insets else { return }
        let anchor = collectionView.captureLocalizationAnchor()
        previousInsets = insets
        collectionView.contentInset = insets; collectionView.scrollIndicatorInsets = insets
        collectionView.collectionViewLayout.invalidateLayout(); collectionView.layoutIfNeeded()
        if let anchor { collectionView.restoreLocalizationAnchor(anchor) }
    }
    func render(comments: [VideoComment], user: String, errorKey: String?, loading: Bool, hasMore: Bool) {
        adapter.apply(transaction: .disabled) {
            ListSection("comments") {
                for comment in comments {
                    Row(comment.id, model: comment, cell: ShortVideoCommentCell.self) { [weak self] cell, item, _ in
                        cell.configure(item, delete: item.author.id == user ? { [weak self] in self?.deleteRequested?(item) } : nil)
                    }
                }
                if let errorKey {
                    Row("error", model: Localization.text(errorKey), cell: UICollectionViewListCell.self) { cell, text, _ in
                        var config = UIListContentConfiguration.cell(); config.text = text
                        config.textProperties.numberOfLines = 0; cell.contentConfiguration = config
                    }
                } else if comments.isEmpty && loading {
                    Row("loading", model: Localization.text("chat.list.loading"), cell: UICollectionViewListCell.self) { cell, text, _ in
                        var config = UIListContentConfiguration.cell(); config.text = text
                        config.textProperties.color = .secondaryLabel; config.textProperties.alignment = .center
                        cell.contentConfiguration = config
                    }
                } else if comments.isEmpty && !loading {
                    Row("empty", model: Localization.text("shortVideo.noComments"), cell: UICollectionViewListCell.self) { cell, text, _ in
                        var config = UIListContentConfiguration.cell(); config.text = text
                        config.textProperties.numberOfLines = 0; config.textProperties.alignment = .center
                        config.textProperties.color = .secondaryLabel; cell.contentConfiguration = config
                    }
                }
                if (hasMore || errorKey != nil) && !loading {
                    Row("more", model: Localization.text(errorKey == nil ? "shortVideo.more" : "shortVideo.retry"), cell: UICollectionViewListCell.self) { cell, text, _ in
                        var config = UIListContentConfiguration.cell(); config.text = text
                        config.textProperties.color = .link; cell.contentConfiguration = config
                    }.onSelect { [weak self] _, _ in self?.retryRequested?() }
                }
            }.layout(.custom(id: "comments") { _, _, _ in
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(96))
                let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                section.contentInsets = .init(top: 8, leading: 0, bottom: 8, trailing: 0)
                return section
            })
        }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("评论列表空状态") {
    let view = ShortVideoCommentsView()
    view.render(comments: [], user: "", errorKey: nil, loading: false, hasMore: false)
    return view
}
#endif
