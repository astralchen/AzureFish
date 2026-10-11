import AVFoundation
import AzureFishStorage
import AzureFishAPI
import AzureFishMoments
import ImageIO
import PhotosUI
import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 协调发布编辑器、系统媒体选择器及受保护的编辑文件租约。
final class MomentsComposerViewController: LocalizedQuickLayoutHostingController, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    let viewModel: MomentsComposerViewModel
    let composerView: MomentsComposerView
    var runtime: MomentsRuntime { viewModel.runtime }
    var draft: MomentsDraft { viewModel.state.draft }
    var isCover: Bool { viewModel.state.isCover }
    var add: UIButton { composerView.add }
    var busy: Bool {
        get { viewModel.state.busy }
        set { viewModel.setBusy(newValue) }
    }
    var errorKey: String? {
        get { viewModel.state.errorKey }
        set { viewModel.setError(newValue) }
    }
    /// 裁剪器仍在使用的明文视频及其所属存储，关闭编辑器或页面释放时归还。
    var editingLease: (EncryptedMediaStore, URL)?

    convenience init(runtime: MomentsRuntime, draft: MomentsDraft, cover: Bool = false) {
        self.init(viewModel: MomentsComposerViewModel(runtime: runtime, draft: draft, cover: cover))
    }
    init(viewModel: MomentsComposerViewModel) {
        self.viewModel = viewModel
        composerView = MomentsComposerView(media: MomentsMediaProvider(runtime: viewModel.runtime), state: viewModel.state)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { isCover ? "moments.changeCover" : "moments.publish" }
    override var body: Layout { composerView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity) }
    override func viewDidLoad() {
        super.viewDidLoad()
        quickLayoutKeyboardSafeAreaBehavior = .docked()
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        navigationController?.presentationController?.delegate = self
        bind()
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        guard isViewLoaded else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Localization.text("account.design.cancel"), primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: Localization.text(draft.publication == nil ? "moments.publish" : "moments.retry"), primaryAction: UIAction { [weak self] _ in self?.viewModel.publish() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "moments.editor.publish"
        composerView.apply(viewModel.state, localizationChanged: true)
        updateControls()
    }
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { close() }
    /// 呈现保存或丢弃草稿的选择；已冻结草稿不提供丢弃入口。
    func close() {
        viewModel.cancelPendingSave()
        let alert = UIAlertController(title: Localization.text("moments.keepDraft"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("moments.saveDraft"), style: .default) { [weak self] _ in self?.viewModel.leave(save: true) })
        if !viewModel.state.frozen { alert.addAction(UIAlertAction(title: Localization.text("moments.discardDraft"), style: .destructive) { [weak self] _ in self?.viewModel.leave(save: false) }) }
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel)); present(alert, animated: true)
    }

    isolated deinit {
        viewModel.stop()
        if let (media, url) = editingLease { Task { try? await media.release(url) } }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈发布") { AppNavigationController(rootViewController: MomentsComposerViewController(runtime: MomentsPreviewData.runtime(), draft: MomentsDraft())) }
#endif
