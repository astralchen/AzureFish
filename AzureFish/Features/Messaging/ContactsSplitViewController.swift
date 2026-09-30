import AzureFishAPI
import QuickLayoutKit
import UIKit

/// 通讯录窄屏导航和宽屏双栏共享列表、选中资料及详情栈。
final class ContactsSplitViewController: UIViewController, UISplitViewControllerDelegate {
    private let runtime: ChatRuntime
    private let split = UISplitViewController(style: .doubleColumn)
    private var selectedID: String?
    private weak var preservedFocus: UIView?
    private var preservedSelection: (start: Int, end: Int)?
    init(runtime: ChatRuntime) { self.runtime = runtime; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let contacts = ContactsViewController(runtime: runtime)
        contacts.showProfile = { [weak self] contact in self?.open(contact) }
        split.delegate = self; split.minimumPrimaryColumnWidth = 280; split.maximumPrimaryColumnWidth = 360
        split.preferredPrimaryColumnWidth = 320; split.preferredDisplayMode = .oneBesideSecondary; split.preferredSplitBehavior = .tile
        split.setViewController(AppNavigationController(rootViewController: contacts), for: .primary)
        split.setViewController(AppNavigationController(rootViewController: ContactSelectionViewController()), for: .secondary)
        addChild(split); view.addSubview(split.view)
        // UIKit 系统容器托管边界；具体内容由 QuickLayout 和 ListKit 管理。
        split.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), split.view.topAnchor.constraint(equalTo: view.topAnchor), split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        split.didMove(toParent: self)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let desired: UIUserInterfaceSizeClass = view.bounds.width >= 840 && traitCollection.horizontalSizeClass == .regular ? .regular : .compact
        if split.traitCollection.horizontalSizeClass != desired {
            preserveEditingFocus()
            setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: desired), forChild: split)
            if let coordinator = transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.restoreEditingFocus() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.restoreEditingFocus() }
            }
        }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        preserveEditingFocus()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.restoreEditingFocus() }
    }
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews {
            if let focused = firstResponder(in: child) { return focused }
        }
        return nil
    }
    private func preserveEditingFocus() {
        guard preservedFocus == nil, let focused = firstResponder(in: view) else { return }
        preservedFocus = focused
        if let input = focused as? any UITextInput, let range = input.selectedTextRange {
            preservedSelection = (input.offset(from: input.beginningOfDocument, to: range.start),
                                  input.offset(from: input.beginningOfDocument, to: range.end))
        }
    }
    private func restoreEditingFocus() {
        defer { preservedFocus = nil; preservedSelection = nil }
        // 系统双栏重挂导航控制器会结束编辑；仅恢复仍留在本容器的原输入框。
        guard let focused = preservedFocus, focused.window != nil, focused.isDescendant(of: view),
              firstResponder(in: view) == nil || focused.isFirstResponder else { return }
        focused.becomeFirstResponder()
        if let selection = preservedSelection, let input = focused as? any UITextInput,
           let start = input.position(from: input.beginningOfDocument, offset: selection.start),
           let end = input.position(from: input.beginningOfDocument, offset: selection.end) {
            input.selectedTextRange = input.textRange(from: start, to: end)
        }
    }
    private func open(_ contact: ChatContact) {
        if selectedID == contact.peer.id { split.show(.secondary); return }
        selectedID = contact.peer.id
        split.showDetailViewController(AppNavigationController(rootViewController: FriendViewController(runtime: runtime, contact: contact)), sender: self)
    }
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        selectedID == nil ? .primary : .secondary
    }
}
final class ContactSelectionViewController: ContactFormController {
    override var localizedTitleKey: String? { "chat.live.contacts" }
    override func viewDidLoad() { super.viewDidLoad(); reloadLocalizedContent() }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); fields = [text(Localization.text("contacts.select"), style: .title2)]; setNeedsQuickLayout()
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("通讯录双栏") { ContactsSplitViewController(runtime: ChatRuntime(previewContacts: ConversationPreviewData.contacts)) }
@available(iOS 17.0, *)
#Preview("选择联系人") { ContactSelectionViewController() }
#endif
