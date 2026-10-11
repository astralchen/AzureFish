import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 协调朋友圈与个人相册的页面生命周期、导航和系统呈现。
final class MomentsViewController: LocalizedQuickLayoutHostingController {
    let viewModel: MomentsViewModel
    let feedView: MomentsFeedView
    var runtime: MomentsRuntime { viewModel.runtime }
    var author: String { viewModel.author }

    convenience init(runtime: MomentsRuntime, author: String = "") {
        self.init(viewModel: MomentsViewModel(runtime: runtime, author: author))
    }
    init(viewModel: MomentsViewModel) {
        self.viewModel = viewModel
        feedView = MomentsFeedView(media: MomentsMediaProvider(runtime: viewModel.runtime))
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { author.isEmpty ? "moments.title" : "moments.album" }
    override var body: Layout { feedView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity) }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setContentScrollView(feedView.list, for: .top)
        bind()
        NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .momentsChanged, object: nil)
        reloadLocalizedContent()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.publishState()
        viewModel.refresh()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        feedView.isVisible = true
        feedView.loadNextPageIfNeeded()
    }
    override func viewWillDisappear(_ animated: Bool) {
        feedView.isVisible = false
        super.viewWillDisappear(animated)
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        guard isViewLoaded else { return }
        if author.isEmpty || author == runtime.userID {
            let add = UIBarButtonItem(image: UIImage(systemName: "square.and.pencil"), primaryAction: UIAction { [weak self] _ in self?.compose() })
            add.accessibilityLabel = Localization.text("moments.publish")
            add.accessibilityIdentifier = "moments.compose"
            navigationItem.rightBarButtonItem = add
        }
        viewModel.publishState()
    }
    /// 当前账号的其他窗口提交后刷新可见页面；自身广播不重复触发刷新。
    @objc private func changed(_ notification: Notification) {
        guard notification.userInfo?["user"] as? String == runtime.userID,
              (notification.object as? MomentsRuntime) !== runtime, viewIfLoaded?.window != nil else { return }
        viewModel.refresh()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈") { AppNavigationController(rootViewController: MomentsViewController(runtime: MomentsPreviewData.runtime())) }
#endif
