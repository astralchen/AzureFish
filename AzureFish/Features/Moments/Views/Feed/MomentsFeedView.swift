import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 管理动态列表渲染、尺寸与阅读锚点；业务状态由页面视图模型提供。
final class MomentsFeedView: QuickLayoutView, UIScrollViewDelegate {
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    private let media: MomentsMediaProvider
    var action: ((MomentsAction, MomentsPost) -> Void)?
    var openCover: ((UIView) -> Void)?
    var refresh: (() -> Void)?
    var retry: (() -> Void)?
    /// 请求续页；参数为 true 表示用户点击重试，false 表示滚动或布局自动触发。
    var loadNext: ((Bool) -> Void)?
    var isVisible = false
    private var state: MomentsFeedState?
    private struct Presentation: Equatable {
        let posts: [MomentsPost]
        let album: MomentsAlbum
        let expanded: Set<String>
        let busy: Set<String>
        let width: CGFloat
        let appearance: String
        let status: String?
        let loading: Bool
        let footer: MomentsPaginationState?
        let canCompose: Bool
    }
    private var presentation: Presentation?
    private var rowVersions: [String: UInt64] = [:]
    private var headerVersion: UInt64 = 0
    private var width: CGFloat = 0

    init(media: MomentsMediaProvider) {
        self.media = media
        super.init(frame: .zero)
        list.backgroundColor = .systemBackground
        list.contentInsetAdjustmentBehavior = .automatic
        list.alwaysBounceVertical = true
        list.accessibilityIdentifier = "moments.list"
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        adapter.scrollDelegate = self
        let control = UIRefreshControl()
        list.refreshControl = control
        control.addAction(UIAction { [weak self] _ in self?.refresh?() }, for: .valueChanged)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout { list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity) }
    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(width - list.bounds.width) > 1 {
            width = list.bounds.width
            if let state { apply(state) }
            list.collectionViewLayout.invalidateLayout()
        }
        loadNextPageIfNeeded()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if let state { apply(state) }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { loadNextPageIfNeeded() }
    /// 减速、布局填充及续页完成均检查距离，业务层负责去重和失败后的重试策略。
    func loadNextPageIfNeeded() {
        guard isVisible, state?.footer == .idle, list.bounds.height > 0, list.contentSize.height > 0 else { return }
        // 删除记录可能占满一页；即使占位页较高，也须继续推进已取得的游标。
        if state?.posts.isEmpty == true { loadNext?(false); return }
        let bottom = list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom
        if bottom >= list.contentSize.height - 240 { loadNext?(false) }
    }
    /// 按内容和显示环境更新列表快照，尽可能保留首个可见动态的位置；布局可能稍后完成。
    func apply(_ state: MomentsFeedState) {
        self.state = state
        list.semanticContentAttribute = Localization.currentUIKitDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        let posts = state.posts, album = state.album, expanded = state.expanded, busy = state.busy, status = state.status
        let appearance = Localization.localizationController.currentLocale.identifier
            + ":\(Localization.currentUIKitDirection.rawValue):" + traitCollection.preferredContentSizeCategory.rawValue
            + ":\(traitCollection.userInterfaceStyle.rawValue):\(traitCollection.accessibilityContrast.rawValue)"
        let next = Presentation(posts: posts, album: album, expanded: expanded, busy: busy, width: width,
            appearance: appearance, status: status, loading: state.loading, footer: state.footer, canCompose: state.canCompose)
        // 后台校验、草稿通知和系统菜单可能不改变可见数据，此时保留整个列表快照。
        guard presentation != next else { return }
        let previous = presentation
        presentation = next
        let oldPosts = Dictionary(uniqueKeysWithValues: (previous?.posts ?? []).map { ($0.id, $0) })
        let surviving = Set(posts.map(\.id))
        rowVersions = rowVersions.filter { surviving.contains($0.key) }
        for post in posts where oldPosts[post.id] != post || previous?.width != width || previous?.appearance != appearance
            || previous?.expanded.contains(post.id) != expanded.contains(post.id)
            || previous?.busy.contains(post.id) != busy.contains(post.id)
            || (previous?.canCompose == false && next.canCompose) {
            rowVersions[post.id, default: 0] &+= 1
        }
        if previous?.album != album || previous?.appearance != appearance || (previous?.canCompose == false && next.canCompose) { headerVersion &+= 1 }
        // 使用稳定动态 ID 保持阅读位置，避免前方内容增删或高度变化后按旧下标跳动。
        let anchor = list.indexPathsForVisibleItems.sorted().first.flatMap { list.cellForItem(at: $0)?.accessibilityIdentifier }.flatMap { $0.hasPrefix("moment.row.") ? String($0.dropFirst(11)) : nil }
        var transaction = ListTransaction.disabled
        if let anchor, posts.contains(where: { $0.id == anchor }) { transaction = transaction.scrollBehavior(.preserveVisiblePosition(of: .init(anchor))) }
        adapter.apply(transaction: transaction) {
            ListSection("moments") {
                Row("header", model: album, cell: UICollectionViewListCell.self) { [weak self] cell, album, _ in
                    guard let self else { return }
                    cell.contentConfiguration = MomentsHeaderConfiguration(album: album, media: media, open: { [weak self] source in self?.openCover?(source) })
                    cell.backgroundConfiguration = .clear(); cell.accessories = []
                    cell.accessibilityIdentifier = "moments.header"; cell.isUserInteractionEnabled = true
                }.refreshID(headerVersion).refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                if let key = status {
                    Row("status", model: key, cell: UICollectionViewListCell.self) { cell, key, _ in
                        var config = UIListContentConfiguration.subtitleCell(); config.text = Localization.text(key)
                        config.secondaryText = Localization.text("moments.retry"); config.textProperties.numberOfLines = 0
                        cell.contentConfiguration = config; cell.accessibilityIdentifier = "moments.status"
                        cell.accessories = []; cell.isUserInteractionEnabled = true
                    }.refreshID(key + appearance).refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                        .onSelect { [weak self] _, _ in self?.retry?() }
                }
                if posts.isEmpty {
                    Row("empty", model: next.loading, cell: UICollectionViewListCell.self) { cell, loading, _ in
                        var config = UIListContentConfiguration.cell(); config.text = Localization.text(loading ? "moments.loading" : "moments.empty")
                        config.textProperties.numberOfLines = 0; config.textProperties.color = .secondaryLabel
                        cell.contentConfiguration = config; cell.accessibilityIdentifier = "moments.empty"
                        cell.accessories = []; cell.isUserInteractionEnabled = true
                    }.refreshID("\(next.loading):" + appearance).refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                }
                ListKit.ForEach(posts, id: \.id) { post in
                    Row(post.id, model: post, cell: UICollectionViewListCell.self) { [weak self] cell, post, _ in
                        guard let self else { return }
                        cell.contentConfiguration = MomentsPostConfiguration(post: post, media: media, width: max(280, width), expanded: expanded.contains(post.id),
                            action: { [weak self] action in self?.action?(action, post) })
                        cell.backgroundConfiguration = .clear(); cell.accessories = []; cell.isUserInteractionEnabled = !busy.contains(post.id)
                        cell.accessibilityIdentifier = "moment.row." + post.id
                    }.refreshID(rowVersions[post.id, default: 0]).refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                }
            }.layout(.custom(id: "moments") { _, _, env in
                var config = UICollectionLayoutListConfiguration(appearance: .plain); config.showsSeparators = true; config.backgroundColor = .systemBackground
                return NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
            })
            if let footer = next.footer {
                ListSection("pagination") {
                    Row("pagination", model: footer, cell: MomentsPaginationCell.self) { cell, state, _ in
                        cell.contentConfiguration = MomentsPaginationConfiguration(state: state)
                        cell.backgroundConfiguration = .clear(); cell.accessories = []
                        cell.accessibilityIdentifier = "moments.pagination." + state.rawValue
                        cell.isAccessibilityElement = true; cell.accessibilityLabel = state.label
                        cell.accessibilityTraits = state.allowsRetry ? .button : .staticText
                        cell.isUserInteractionEnabled = state.allowsRetry
                    }.refreshID(footer.rawValue + appearance).refresh(when: .refreshIDChanges, action: .reconfigure(layout: .invalidate))
                        .onSelect { [weak self] state, _ in if state.allowsRetry { self?.loadNext?(true) } }
                }.layout(.custom(id: "pagination") { _, _, env in
                    var config = UICollectionLayoutListConfiguration(appearance: .plain)
                    config.showsSeparators = false; config.backgroundColor = .systemBackground
                    return NSCollectionLayoutSection.list(using: config, layoutEnvironment: env)
                })
            }
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈列表") { MomentsFeedView.preview() }
#endif

#if DEBUG
private extension MomentsFeedView {
    static func preview() -> MomentsFeedView {
        let runtime = MomentsPreviewData.runtime()
        let view = MomentsFeedView(media: MomentsMediaProvider(runtime: runtime))
        view.apply(MomentsViewModel(runtime: runtime).state)
        return view
    }
}
#endif
