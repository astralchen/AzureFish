import AzureFishAPI
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 与 ConversationView 一样封装集合视图和 ListKit，页面只传入素材并接收滚动事件。
final class ShortVideoFeedView: QuickLayoutView {
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    let loading = UIActivityIndicatorView(style: .large)
    let retry = UIButton(type: .system)
    private let status = UILabel()
    private let statusBackground = UIView()
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    weak var scrollDelegate: (any UIScrollViewDelegate)? {
        didSet { adapter.scrollDelegate = scrollDelegate }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; list.backgroundColor = .black
        list.isPagingEnabled = true; list.showsVerticalScrollIndicator = false
        list.contentInsetAdjustmentBehavior = .never
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        status.textColor = .white; status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true; status.numberOfLines = 0; status.textAlignment = .center
        statusBackground.backgroundColor = .black; statusBackground.layer.cornerRadius = 16
        loading.color = .white; retry.tintColor = .white
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        ZStack {
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                loading.frame(width: 44, height: 44)
                status.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                retry.frame(minHeight: 44)
            }.padding(24).background { statusBackground.resizable() }
                .padding(24).safeAreaPadding(.all, 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    /// 加载／状态浮层只拦截重试按钮，其余触摸仍由集合视图处理翻页和点按。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = super.hitTest(point, with: event) else { return nil }
        var candidate: UIView? = target
        while let view = candidate, view !== self {
            if view is UIControl { return target }
            candidate = view.superview
        }
        if target === list || target.isDescendant(of: list) { return target }
        return list.hitTest(convert(point, to: list), with: event)
    }
    func renderStatus(errorKey: String?, empty: Bool, hasMore: Bool) {
        status.text = errorKey.map(Localization.text) ?? (empty ? Localization.text("shortVideo.empty") : nil)
        retry.setTitle(Localization.text(errorKey != nil ? "shortVideo.retry" : "shortVideo.more"), for: .normal)
        retry.isHidden = errorKey == nil && !(empty && hasMore)
        statusBackground.isHidden = status.text == nil && retry.isHidden
        setNeedsQuickLayout()
    }
    func apply(_ items: [ShortVideoItem]) {
        adapter.apply(transaction: .disabled) {
            ListSection("videos") {
                for item in items { Row(item.id, model: item.id, cell: ShortVideoCell.self) { _, _, _ in } }
            }.layout(.custom(id: "video-pages") { _, _, _ in
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
                return NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            })
        }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频列表错误状态") {
    let view = ShortVideoFeedView()
    view.renderStatus(errorKey: "shortVideo.unconfigured", empty: true, hasMore: true)
    return view
}
#endif
