import Combine
import AppLocalization
import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import UIKit

/// 组合评论列表与输入栏；沿用 Chat 的底部覆盖布局和键盘遮挡协调器。
final class ShortVideoCommentsViewController: LocalizedQuickLayoutHostingController {
    let viewModel: ShortVideoCommentsViewModel
    private let commentsView = ShortVideoCommentsView()
    private let composerView = ShortVideoCommentComposerView()
    private let keyboardObserver = QuickLayoutKeyboardObserver()
    private lazy var obstruction = BottomObstructionCoordinator(hostView: view)
    private var bottomObstruction: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()
    private var observer: UUID?
    private var foreground: (any NSObjectProtocol)?
    var commentCount: Int64 = 0 { didSet { updateTitle() } }
    var closed: (() -> Void)?

    convenience init(runtime: ShortVideoRuntime, video: String) {
        self.init(viewModel: ShortVideoCommentsViewModel(runtime: runtime, video: video))
    }
    init(viewModel: ShortVideoCommentsViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "shortVideo.comments" }
    override var body: Layout {
        ZStack(alignment: .bottom) {
            commentsView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            composerView.resizable(axis: .horizontal).fixedSize(axis: .vertical)
                .padding(.bottom, bottomObstruction).safeAreaPadding([.horizontal, .bottom], 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        viewModel.stateChanged = { [weak self] in self?.render() }
        composerView.textChanged = { [weak self] in self?.viewModel.draft = $0 }
        composerView.heightDidChange = { [weak self] in self?.setNeedsQuickLayout() }
        composerView.send.addAction(UIAction { [weak self] _ in self?.viewModel.submit() }, for: .touchUpInside)
        commentsView.deleteRequested = { [weak self] in self?.confirmDelete($0) }
        commentsView.retryRequested = { [weak self] in
            guard let self else { return }
            viewModel.read(reset: viewModel.comments.isEmpty || !viewModel.hasMore)
        }
        observer = viewModel.runtime.observeStop { [weak self] in self?.dismiss(animated: false) }
        keyboardObserver.$context.dropFirst().sink { [weak self] context in
            self?.obstruction.updateKeyboard(context)
        }.store(in: &cancellables)
        obstruction.heightDidChange = { [weak self] height, context in
            guard let self else { return }
            bottomObstruction = height; setNeedsQuickLayout()
            let update = { [weak self] in self?.view.layoutIfNeeded(); self?.updateViewport() }
            if let context, context.animationDuration > 0 {
                UIView.animate(withDuration: context.animationDuration, delay: 0,
                    options: context.animationOptions.union(.beginFromCurrentState), animations: update)
            } else { update() }
        }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, viewIfLoaded?.window != nil else { return }; viewModel.read(reset: true)
            }
        }
        reloadLocalizedContent()
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); viewModel.read(reset: true) }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); viewModel.stopReading() }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); obstruction.refreshGeometry(); updateViewport() }
    private func updateViewport() {
        guard composerView.bounds.height > 0 else { return }
        let safe = view.safeAreaInsets
        commentsView.updateViewportInsets(.init(top: safe.top, left: safe.left,
            bottom: safe.bottom + bottomObstruction + composerView.bounds.height, right: safe.right))
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }
        navigationItem.setBarButtonItem(UIBarButtonItem(image: UIImage(systemName: "xmark"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; view.endEditing(true); dismiss(animated: true) { [weak self] in self?.closed?() }
        }), side: .trailing)
        navigationItem.rightBarButtonItem?.accessibilityLabel = Localization.text("common.close")
        updateTitle(); render()
    }
    private func updateTitle() {
        let count = commentCount.formatted(.number.locale(Localization.localizationController.locale))
        navigationItem.title = String(format: Localization.text("shortVideo.commentCount"), count)
    }
    override func reloadLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        super.reloadLayoutDirection(direction)
        navigationController?.navigationBar.semanticContentAttribute = direction.appLayoutDirection.semanticContentAttribute
        commentsView.applyLayoutDirection(direction)
        composerView.applyLayoutDirection(direction)
    }
    private func render() {
        commentsView.render(comments: viewModel.comments, user: viewModel.runtime.userID,
            errorKey: viewModel.errorKey, loading: viewModel.loading, hasMore: viewModel.hasMore)
        composerView.apply(draft: viewModel.draft, busy: viewModel.busy)
    }
    private func confirmDelete(_ comment: VideoComment) {
        guard comment.author.id == viewModel.runtime.userID, !viewModel.busy else { return }
        let alert = UIAlertController(title: Localization.text("shortVideo.deleteConfirm"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("shortVideo.delete"), style: .destructive) { [weak self] _ in self?.viewModel.delete(comment) })
        present(alert, animated: true)
    }
    isolated deinit {
        obstruction.stop()
        if let observer { viewModel.runtime.remove(observer) }
        if let foreground { NotificationCenter.default.removeObserver(foreground) }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频评论") { AppNavigationController(rootViewController: ShortVideoCommentsViewController(runtime: ShortVideoRuntime(), video: "pixabay:1")) }
#endif
