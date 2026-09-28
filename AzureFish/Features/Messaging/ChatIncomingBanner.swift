import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 场景窗口记录实际触摸，不改变事件分发或当前输入焦点。
final class ChatInteractionWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, event.allTouches?.contains(where: { $0.phase == .began }) == true,
           let windowScene { ChatIncomingBannerCoordinator.interacted(with: windowScene) }
        super.sendEvent(event)
    }
}

/// 账号根容器内的临时消息提醒；不使用系统通知权限或后台推送。
@MainActor
final class ChatIncomingBannerCoordinator {
    private final class WeakEntry {
        weak var value: ChatIncomingBannerCoordinator?
        init(_ value: ChatIncomingBannerCoordinator) { self.value = value }
    }
    private static var entries: [WeakEntry] = []
    private static var interactionCounter = 0
    private static var delivered: [String] = []
    private var interaction = 0
    private weak var host: UIViewController?
    private let runtime: ChatRuntime
    private let open: (ChatConversation) -> Void
    private let banner = ChatIncomingBannerView()
    private var current: ChatMessage?
    private var currentTitle = ""
    private var checkTask: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var observation: UUID?
    private var tokens: [NSObjectProtocol] = []
    private var generation = 0
    private var active = false
    private var currentScene: UIWindowScene? { host?.viewIfLoaded?.window?.windowScene }

    init(host: UIViewController, runtime: ChatRuntime, open: @escaping (ChatConversation) -> Void) {
        self.host = host; self.runtime = runtime; self.open = open
        Self.entries.removeAll { $0.value == nil }
        Self.entries.append(WeakEntry(self))
        runtime.incomingMessages = { [weak self] in self?.receive($0) }
        observation = runtime.observe { [weak self] in self?.revalidate() }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let scene = note.object as? UIWindowScene
                let notificationName = note.name
                MainActor.assumeIsolated {
                    guard let self, let scene, scene === self.currentScene else { return }
                    if notificationName == UIScene.willDeactivateNotification { self.deactivate() }
                    else { self.updateActivity() }
                }
            })
        }
        banner.close = { [weak self] in self?.hide() }
        banner.open = { [weak self] in self?.openCurrent() }
    }
    func updateActivity() {
        let next = currentScene?.activationState == .foregroundActive && runtime.engine != nil
        if next != active {
            active = next
            generation += 1
            if next, let currentScene { Self.interacted(with: currentScene) }
            else { hide() }
        }
        Self.refreshForegroundScopes()
    }
    private func deactivate() {
        active = false; generation += 1
        Self.refreshForegroundScopes()
        checkTask?.cancel(); hide()
    }
    private static func refreshForegroundScopes() {
        let coordinators = entries.compactMap(\.value)
        for coordinator in coordinators {
            guard let store = coordinator.runtime.engine?.store else { continue }
            let hasActiveScene = coordinators.contains {
                $0.active && $0.currentScene?.activationState == .foregroundActive
                    && $0.runtime.engine?.store.userID == store.userID
                    && $0.runtime.engine?.store.environment == store.environment
            }
            // 同账号共享库可能由其他场景先提交事件；生成提醒按账号前台状态，展示再选窗口。
            coordinator.runtime.setForeground(hasActiveScene)
        }
    }
    static func interacted(with scene: UIWindowScene) {
        interactionCounter += 1
        for entry in entries {
            if entry.value?.currentScene === scene { entry.value?.interaction = interactionCounter }
            else { entry.value?.hide() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            for entry in entries { entry.value?.revalidate() }
        }
    }
    private var selectedCoordinator: ChatIncomingBannerCoordinator? {
        guard let store = runtime.engine?.store else { return nil }
        return Self.entries.compactMap(\.value).filter {
            $0.active && $0.currentScene?.activationState == .foregroundActive
                && $0.runtime.engine?.store.userID == store.userID && $0.runtime.engine?.store.environment == store.environment
        }.max(by: { $0.interaction < $1.interaction })
    }
    private var isSelectedScene: Bool { active && selectedCoordinator === self }
    private func displayedConversation() -> String? {
        func visible(_ controller: UIViewController) -> UIViewController {
            if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController { return visible(selected) }
            if let nav = controller as? UINavigationController, let top = nav.topViewController { return visible(top) }
            if let split = controller as? UISplitViewController, let last = split.viewControllers.last { return visible(last) }
            if let child = controller.children.last { return visible(child) }
            return controller
        }
        guard let host else { return nil }
        let page = visible(host)
        let pages = [page] + (page.navigationController?.viewControllers.reversed().map { $0 } ?? [])
        for page in pages {
            if let page = page as? ConversationDetailsViewController { return page.conversationID }
            if let page = page as? ConversationSearchViewController { return page.conversationID }
            if let page = page as? LiveConversationViewController { return page.conversationID }
            if #available(iOS 26.0, *), let page = page as? ChatViewController, let session = page.session as? LiveChatSession { return session.conversation.id }
        }
        return nil
    }
    private func receive(_ messages: [ChatMessage]) {
        // 同账号任一前台场景先提交的事件，交给最近交互场景展示。
        selectedCoordinator?.enqueue(messages)
    }
    private func enqueue(_ messages: [ChatMessage]) {
        guard isSelectedScene else { return }
        // 同一批次按会话合并，只保留最新摘要；横幅是临时提示，不承担消息送达。
        let candidates = Dictionary(grouping: messages, by: \.conversationID).compactMap { $0.value.max { $0.sequence < $1.sequence } }.sorted { $0.createdAt < $1.createdAt }
        let version = generation
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self, let engine = runtime.engine else { return }
            for candidate in candidates {
                do {
                    let preference = try await engine.store.conversationPreferences(candidate.conversationID)
                    guard !preference.isMuted,
                          let message = try await engine.store.visibleMessage(candidate.id, conversation: candidate.conversationID) else { continue }
                    let conversations = try await engine.store.conversations()
                    guard let conversation = conversations.first(where: { $0.id == message.conversationID }) else { continue }
                    try Task.checkCancellation()
                    guard runtime.engine === engine, generation == version, isSelectedScene,
                          displayedConversation() != message.conversationID,
                          !runtime.preference(message.conversationID).isMuted else { continue }
                    let key = engine.store.environment + ":" + engine.store.userID.uuidString + ":" + message.id
                    guard !Self.delivered.contains(key) else { continue }
                    Self.delivered.append(key)
                    if Self.delivered.count > 512 { Self.delivered.removeFirst(Self.delivered.count - 512) }
                    current = message
                    let sender = conversation.members.first { $0.id == message.senderID }.map { runtime.memberName($0) } ?? Localization.text("chat.live.groupMember")
                    let title = conversation.kind == "group" ? conversation.title + " · " + sender : sender
                    let summary = messageSummary(message)
                    show(title: title, summary: summary)
                } catch is CancellationError { return } catch { continue }
            }
        }
    }
    private func show(title: String, summary: String) {
        currentTitle = title
        guard let view = host?.viewIfLoaded else { return }
        banner.configure(title: title, summary: summary)
        if banner.superview == nil {
            view.addSubview(banner)
            // 根容器覆盖层的安全区域约束；横幅内部仍由 QuickLayout 布局。
            banner.translatesAutoresizingMaskIntoConstraints = false
            let width = banner.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24)
            width.priority = .defaultHigh
            NSLayoutConstraint.activate([width,
                banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
                banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                banner.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
                banner.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
            ])
        }
        view.bringSubviewToFront(banner)
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.hide()
        }
        UIAccessibility.post(notification: .announcement, argument: title + ", " + summary)
    }
    private func revalidate() {
        updateActivity()
        guard let message = current else { return }
        if runtime.preference(message.conversationID).isMuted || displayedConversation() == message.conversationID { hide(); return }
        Task { [weak self] in
            guard let self, let engine = runtime.engine else { return }
            let valid = try? await engine.store.visibleMessage(message.id, conversation: message.conversationID)
            if current?.id == message.id, valid == nil || runtime.engine !== engine { hide() }
        }
    }
    private func openCurrent() {
        guard let message = current, let engine = runtime.engine else { hide(); return }
        Task { [weak self] in
            guard let self else { return }
            let valid = try? await engine.store.visibleMessage(message.id, conversation: message.conversationID)
            let conversations = try? await engine.store.conversations()
            guard current?.id == message.id, runtime.engine === engine, active, valid != nil,
                  let conversation = conversations?.first(where: { $0.id == message.conversationID }) else { hide(); return }
            hide(); open(conversation)
        }
    }
    private func messageSummary(_ message: ChatMessage) -> String {
        if ["text", "link"].contains(message.kind) { return String(message.text.prefix(160)) }
        let kind = ["image", "video", "live_photo", "audio", "file"].contains(message.kind) ? message.kind : "unknown"
        return Localization.text("chat.live." + kind)
    }
    func reloadLocalizedContent() {
        guard let current else { return }
        let summary = messageSummary(current)
        banner.configure(title: currentTitle, summary: summary)
    }
    func hide() {
        current = nil; currentTitle = ""
        banner.removeFromSuperview(); banner.clearContent(); dismissal?.cancel()
    }
    func stop() {
        let scope = runtime.engine.map { $0.store.environment + ":" + $0.store.userID.uuidString + ":" }
        generation += 1; active = false
        runtime.setForeground(false); runtime.incomingMessages = nil
        checkTask?.cancel(); hide()
        if let observation { runtime.remove(observation) }; observation = nil
        tokens.forEach(NotificationCenter.default.removeObserver); tokens = []
        Self.entries.removeAll { $0.value == nil || $0.value === self }
        if let scope, !Self.entries.compactMap(\.value).contains(where: {
            guard let store = $0.runtime.engine?.store else { return false }
            return store.environment + ":" + store.userID.uuidString + ":" == scope
        }) { Self.delivered.removeAll { $0.hasPrefix(scope) } }
        Self.refreshForegroundScopes()
    }
    isolated deinit {
        checkTask?.cancel(); dismissal?.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
        if let observation { runtime.remove(observation) }
    }
}

final class ChatIncomingBannerView: QuickLayoutView {
    private let messageButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    var open: (() -> Void)?
    var close: (() -> Void)?
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        messageButton.contentHorizontalAlignment = .leading
        messageButton.titleLabel?.adjustsFontForContentSizeCategory = true
        messageButton.accessibilityIdentifier = "chat.banner.open"
        messageButton.addAction(UIAction { [weak self] _ in self?.open?() }, for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityIdentifier = "chat.banner.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.close?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(alignment: .center, spacing: 4) {
            messageButton.resizable(axis: .horizontal).frame(minWidth: 160, minHeight: 64)
            closeButton.frame(width: 44, height: 44)
        }.padding(.all, 8)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.separator.cgColor
    }
    func configure(title: String, summary: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title; configuration.subtitle = summary
        configuration.titleAlignment = .leading
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = UIFont.preferredFont(forTextStyle: .headline); return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = UIFont.preferredFont(forTextStyle: .subheadline); return attributes
        }
        configuration.baseForegroundColor = .label
        messageButton.configuration = configuration
        messageButton.accessibilityLabel = title + ", " + summary
        closeButton.accessibilityLabel = Localization.text("chat.details.dismissBanner")
        semanticContentAttribute = Localization.currentUIKitDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        layer.borderColor = UIColor.separator.cgColor
        invalidateIntrinsicContentSize(); setNeedsQuickLayout()
    }
    func clearContent() {
        messageButton.configuration = nil
        messageButton.accessibilityLabel = nil
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("应用内消息") {
    let banner = ChatIncomingBannerView()
    banner.configure(title: "林沐", summary: "周末去海边走走吗？")
    return banner
}
#endif
