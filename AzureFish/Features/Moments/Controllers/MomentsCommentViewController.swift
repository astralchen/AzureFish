import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import UIKit

/// 保留评论输入控件与焦点，绑定提交状态并协调返回导航。
final class MomentsCommentViewController: ContactFormController {
    let viewModel: MomentsCommentViewModel
    private let input = UITextView()

    convenience init(runtime: MomentsRuntime, post: String, reply: ChatUser?) {
        self.init(viewModel: MomentsCommentViewModel(runtime: runtime, post: post, reply: reply))
    }
    init(viewModel: MomentsCommentViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "moments.comment" }
    override func viewDidLoad() {
        super.viewDidLoad()
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.backgroundColor = .secondarySystemBackground
        input.accessibilityIdentifier = "moments.comment.text"
        let holder = QuickLayoutView { [input] in input.resizable().frame(height: 180).frame(maxWidth: .infinity) }
        fields = [holder]
        viewModel.render = { [weak self] state in
            self?.busy = state.busy
            self?.input.isEditable = state.canEdit
            self?.statusKey = state.errorKey
        }
        viewModel.didFinish = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        guard isViewLoaded else { return }
        controls = [action("moments.sendComment", primary: true) { [weak self] in
            guard let self else { return }
            viewModel.send(input.text ?? "")
        }]
        updateBusy()
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈评论") {
    AppNavigationController(rootViewController: MomentsCommentViewController(runtime: MomentsPreviewData.runtime(), post: MomentsPreviewData.posts[0].id, reply: nil))
}
#endif
