import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 发现页的首版入口；保留独立导航栈及系统标签栏行为。
final class DiscoverViewController: LocalizedQuickLayoutHostingController {
    let runtime: MomentsRuntime
    private let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    init(runtime: MomentsRuntime) { self.runtime = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "moments.discover" }
    override var body: Layout { list.resizable().safeAreaPadding(.all, 0) }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemGroupedBackground; list.backgroundColor = .clear
        list.contentInsetAdjustmentBehavior = .never; list.collectionViewLayout = adapter.makeCompositionalLayout()
        navigationItem.largeTitleDisplayMode = .always; navigationController?.navigationBar.prefersLargeTitles = true
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }
        adapter.apply(transaction: .disabled) {
            ListSection("discover") {
                Row("moments", model: Localization.text("moments.title"), cell: UICollectionViewListCell.self) { cell, title, _ in
                    var config = UIListContentConfiguration.cell(); config.text = title; config.image = UIImage(systemName: "camera.macro")
                    cell.contentConfiguration = config; cell.accessories = [.disclosureIndicator()]; cell.accessibilityIdentifier = "moments.entry"
                }.onSelect { [weak self] _, _ in
                    guard let self else { return }; navigationController?.pushViewController(MomentsViewController(runtime: runtime), animated: true)
                }
                Row("short-video", model: Localization.text("shortVideo.title"), cell: UICollectionViewListCell.self) { cell, title, _ in
                    var config = UIListContentConfiguration.cell(); config.text = title; config.image = UIImage(systemName: "play.rectangle")
                    cell.contentConfiguration = config; cell.accessories = [.disclosureIndicator()]; cell.accessibilityIdentifier = "shortVideo.entry"
                }.onSelect { [weak self] _, _ in
                    guard let self else { return }
                    let page = ShortVideoViewController(runtime: runtime.chat?.shortVideos ?? ShortVideoRuntime())
                    navigationController?.pushViewController(page, animated: true)
                }
            }.layout(.custom(id: "discover") { _, _, env in NSCollectionLayoutSection.list(using: .init(appearance: .insetGrouped), layoutEnvironment: env) })
        }
    }
}


#if DEBUG
@available(iOS 17.0, *)
#Preview("发现") { AppNavigationController(rootViewController: DiscoverViewController(runtime: MomentsPreviewData.runtime())) }
#endif
