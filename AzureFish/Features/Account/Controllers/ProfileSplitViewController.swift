import UIKit

/// 个人中心在同一系统主从容器内折叠、展开，详情控件和未提交输入保持原实例。
final class ProfileSplitViewController: UIViewController, UISplitViewControllerDelegate {
    private let split = UISplitViewController(style: .doubleColumn)
    private let session: SessionCoordinator
    private let runtime: ChatRuntime
    private var selected = false
    private weak var preservedFocus: UIView?
    private var preservedSelection: (start: Int, end: Int)?
    private let detailNavigation = AppNavigationController()
    init(session: SessionCoordinator, runtime: ChatRuntime) {
        self.session = session; self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        split.delegate = self; split.preferredDisplayMode = .oneBesideSecondary; split.preferredSplitBehavior = .tile
        split.minimumPrimaryColumnWidth = 280; split.maximumPrimaryColumnWidth = 360; split.preferredPrimaryColumnWidth = 320
        let master = ProfileViewController(session: session, runtime: runtime)
        let overview = ProfileViewController(session: session, runtime: runtime); overview.showsMenu = false
        master.openDetail = { [weak self] controller in
            guard let self else { return }
            selected = true
            if let editor = controller as? EditProfileViewController {
                editor.didFinish = { [weak self] in
                    guard let self else { return }
                    selected = false
                    detailNavigation.setViewControllers([overview], animated: false)
                    split.show(.primary)
                }
            }
            detailNavigation.setViewControllers([controller], animated: false)
            split.showDetailViewController(detailNavigation, sender: self)
        }
        split.setViewController(AppNavigationController(rootViewController: master), for: .primary)
        detailNavigation.setViewControllers([overview], animated: false)
        split.setViewController(detailNavigation, for: .secondary)
        addChild(split); view.addSubview(split.view); split.view.translatesAutoresizingMaskIntoConstraints = false
        // UIKit 容器边界由 Auto Layout 托管，业务页面使用 QuickLayout。
        NSLayoutConstraint.activate([split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        split.didMove(toParent: self)
    }
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let wide = traitCollection.horizontalSizeClass == .regular && view.bounds.inset(by: view.safeAreaInsets).width >= 840
        let desired: UIUserInterfaceSizeClass = wide ? .regular : .compact
        if split.traitCollection.horizontalSizeClass != desired {
            preserveEditingFocus()
            setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: desired), forChild: split)
            DispatchQueue.main.async { [weak self] in self?.restoreEditingFocus() }
        }
    }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        preserveEditingFocus()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.restoreEditingFocus() }
    }
    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let focused = firstResponder(in: child) { return focused } }
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
        guard let focused = preservedFocus, focused.window != nil, focused.isDescendant(of: view),
              firstResponder(in: view) == nil || focused.isFirstResponder else { return }
        focused.becomeFirstResponder()
        if let selection = preservedSelection, let input = focused as? any UITextInput,
           let start = input.position(from: input.beginningOfDocument, offset: selection.start),
           let end = input.position(from: input.beginningOfDocument, offset: selection.end) {
            input.selectedTextRange = input.textRange(from: start, to: end)
        }
    }
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        selected ? .secondary : .primary
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("个人中心自适应导航") { ProfileSplitViewController(session: .configured(), runtime: ChatRuntime(session: .configured())) }
#endif
