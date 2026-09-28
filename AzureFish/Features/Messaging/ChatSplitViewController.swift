import AzureFishAPI
import AzureFishChat
import QuickLayoutKit
import UIKit

/// 宽窗口双栏、窄窗口推入详情；通过容器特征切换复用同一导航状态。
final class ChatSplitViewController: UIViewController, UISplitViewControllerDelegate {
    private let runtime: ChatRuntime
    private let split = UISplitViewController(style: .doubleColumn)
    private var current: UIViewController?
    private var selection: String?
    private var observation: UUID?
    private var restored = false
    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let list = ConversationListViewController(runtime: runtime)
        list.openConversation = { [weak self] in self?.open($0) }
        split.delegate = self
        split.minimumPrimaryColumnWidth = 280
        split.maximumPrimaryColumnWidth = 360
        split.preferredPrimaryColumnWidth = 320
        split.preferredDisplayMode = .oneBesideSecondary
        split.preferredSplitBehavior = .tile
        split.setViewController(UINavigationController(rootViewController: list), for: .primary)
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = Localization.text("chat.live.selectConversation")
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        placeholder.view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.view.centerYAnchor),
        ])
        split.setViewController(UINavigationController(rootViewController: placeholder), for: .secondary)
        addChild(split)
        view.addSubview(split.view)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        split.didMove(toParent: self)
        observation = runtime.observe { [weak self] in self?.restore() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wide = view.bounds.width >= 840 && traitCollection.horizontalSizeClass == .regular
        let desired: UIUserInterfaceSizeClass = wide ? .regular : .compact
        if split.traitCollection.horizontalSizeClass != desired {
            setOverrideTraitCollection(UITraitCollection(horizontalSizeClass: desired), forChild: split)
        }
    }
    private func restore() {
        guard !restored, let store = runtime.engine?.store else { return }
        Task { [weak self] in
            guard let self else { return }
            if let id: String = try? await store.meta("selectedConversation"),
                let conversation = runtime.conversations.first(where: { $0.id == id })
            {
                restored = true
                open(conversation)
            }
        }
    }
    private func open(_ conversation: ChatConversation) {
        if selection == conversation.id {
            split.show(.secondary)
            return
        }
        selection = conversation.id
        let controller = ConversationPageFactory.make(runtime: runtime, conversation: conversation)
        current = controller
        split.showDetailViewController(UINavigationController(rootViewController: controller), sender: self)
        Task { try? await runtime.engine?.store.setMeta(conversation.id, id: "selectedConversation") }
    }
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column { selection == nil ? .primary : .secondary }
    deinit {
        if let observation {
            let runtime = runtime
            Task { @MainActor in runtime.remove(observation) }
        }
    }
}
#if DEBUG
    @available(iOS 17.0, *)
    #Preview("会话导航") { ChatSplitViewController(runtime: ChatRuntime(session: .configured())) }
#endif
