import AppLocalization
import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

final class ConversationListViewController: LiveChatListController {
    var openConversation: ((ChatConversation) -> Void)?
    private let stateView = ChatListStateView(frame: .zero)
    private var renderGeneration = UUID()
    private var summaryTask: Task<Void, Never>?
    private var summaryMessages: [String: ChatMessage] = [:]
    private var pinnedContentSizeCategory: UIContentSizeCategory?
    private var synchronizationFailed = false
    private var keyboardFrame: CGRect?
    let pinnedToggle = UIButton(type: .system)
    private var showsPinnedToggle = false
    private var savingPinnedToggle = false
    override var body: Layout {
        VStack(spacing: 0) {
            if runtime.session.phase == .signedIn && runtime.session.readOnly { connectionLabel.resizable(axis: .horizontal).padding(16) }
            if showsPinnedToggle {
                pinnedToggle.resizable(axis: .horizontal).frame(minHeight: 44).padding(.horizontal, 16)
            }
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
        }.ignoresSafeArea(.container)
    }
    override var localizedTitleKey: String? { "account.design.chat" }
    override var showsSeparators: Bool { false }
    override var usesConversationLayout: Bool { true }
    override func viewDidLoad() {
        quickLayoutKeyboardSafeAreaBehavior = .disabled
        super.viewDidLoad()
        pinnedToggle.accessibilityIdentifier = "chat.list.pinnedToggle"
        pinnedToggle.addAction(UIAction { [weak self] _ in self?.togglePinned() }, for: .touchUpInside)
        stateView.content.retry = { [weak self] in self?.runtime.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        navigationController?.navigationBar.prefersLargeTitles = true
        selected = { [weak self] id in
            guard let self, let c = runtime.conversations.first(where: { $0.id == id }) else { return }
            open(c)
        }
        menu()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateViewport()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded, previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            reloadRows()
        }
    }
    @objc private func keyboardChanged(_ notification: Notification) {
        keyboardFrame = notification.name == UIResponder.keyboardWillHideNotification ? nil
            : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        updateViewport()
    }
    private func updateViewport() {
        var overlap: CGFloat = 0
        if let keyboardFrame, let window = view.window {
            let frame = list.convert(window.convert(keyboardFrame, from: window.screen.coordinateSpace), from: window)
            let intersection = list.bounds.intersection(frame)
            // 浮动键盘不把整个列表底部变成额外留白。
            if !intersection.isNull, intersection.maxY >= list.bounds.maxY - 1,
                intersection.width >= list.bounds.width * 0.9 { overlap = intersection.height }
        }
        let systemBottom = max(0, list.adjustedContentInset.bottom - list.contentInset.bottom)
        let bottom = max(0, overlap - systemBottom)
        if abs(list.contentInset.bottom - bottom) > 0.5 { list.contentInset.bottom = bottom }
        stateView.viewportInsets = list.adjustedContentInset
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        if isViewLoaded { menu() }
    }
    private func menu() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), primaryAction: nil,
            menu: UIMenu(children: [
                UIAction(title: Localization.text("chat.live.newChat"), image: UIImage(systemName: "square.and.pencil"))
                { [weak self] _ in self?.choose(group: false) },
                UIAction(title: Localization.text("chat.live.newGroup"), image: UIImage(systemName: "person.3")) {
                    [weak self] _ in self?.choose(group: true)
                },
            ]))
    }
    private func choose(group: Bool) {
        let chooser = FriendPickerViewController(runtime: runtime, group: group)
        chooser.completed = { [weak self] c in self?.open(c) }
        navigationController?.pushViewController(chooser, animated: true)
    }
    func open(_ conversation: ChatConversation) {
        if let openConversation {
            openConversation(conversation)
        } else {
            navigationController?.pushViewController(
                ConversationPageFactory.make(runtime: runtime, conversation: conversation), animated: true)
        }
    }
    override func trailingActions(for id: String) -> UISwipeActionsConfiguration? {
        guard runtime.visibleSortedConversations.contains(where: { $0.id == id }) else { return nil }
        let unread = UIContextualAction(style: .normal, title: Localization.text("chat.list.markUnread")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                do { try await runtime.markConversationUnread(id); completion(true) }
                catch { completion(false); showError(error) }
            }
        }
        unread.backgroundColor = .systemBlue
        let hide = UIContextualAction(style: .normal, title: Localization.text("chat.list.hide")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                do { try await runtime.hideConversation(id); completion(true) }
                catch { completion(false); showError(error) }
            }
        }
        hide.backgroundColor = .systemGray
        let delete = UIContextualAction(style: .destructive, title: Localization.text("chat.list.delete")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            // 先结束滑动状态，确认取消时不会留下已执行的视觉反馈。
            completion(false)
            let alert = UIAlertController(title: Localization.text("chat.list.deleteTitle"),
                message: Localization.text("chat.list.deleteHelp"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: Localization.text("chat.list.delete"), style: .destructive) { [weak self] _ in
                guard let self else { return }
                Task {
                    do { try await runtime.hideConversation(id, deleting: true) }
                    catch { showError(error) }
                }
            })
            present(alert, animated: true)
        }
        let configuration = UISwipeActionsConfiguration(actions: [delete, hide, unread])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    private func togglePinned() {
        guard !savingPinnedToggle else { return }
        savingPinnedToggle = true
        pinnedToggle.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { savingPinnedToggle = false; pinnedToggle.isEnabled = true }
            do { try await runtime.setPinnedConversationsCollapsed(!runtime.pinnedConversationsCollapsed) }
            catch { showError(error) }
        }
    }
    private func configurePinnedToggle(_ pinned: [ChatConversation]) {
        let visible = query.isEmpty && !pinned.isEmpty && runtime.failure == nil
        if showsPinnedToggle != visible { showsPinnedToggle = visible; setNeedsQuickLayout() }
        let collapsed = runtime.pinnedConversationsCollapsed
        var config = UIButton.Configuration.plain()
        config.title = Localization.text(collapsed ? "chat.list.expandPinned" : "chat.list.collapsePinned")
        let locale = Locale(identifier: Localization.localizationController.currentLocale.identifier)
        let unread = pinned.filter { $0.readState.unread > 0 || runtime.listStates[$0.id]?.manuallyUnread == true }.count
        config.subtitle = String(format: Localization.text("chat.list.pinnedSummary"), locale: locale,
                                 pinned.count.formatted(.number.locale(locale)), unread.formatted(.number.locale(locale)))
        if pinnedToggle.configuration?.title == config.title,
           pinnedToggle.configuration?.subtitle == config.subtitle,
           pinnedContentSizeCategory == traitCollection.preferredContentSizeCategory { return }
        pinnedContentSizeCategory = traitCollection.preferredContentSizeCategory
        config.image = UIImage(systemName: collapsed ? "chevron.down" : "chevron.up")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.titleLineBreakMode = .byWordWrapping
        config.subtitleLineBreakMode = .byWordWrapping
        let titleFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        let subtitleFont = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: titleFont, scale: .small)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var value = $0; value.font = titleFont; return value
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var value = $0; value.font = subtitleFont; return value
        }
        pinnedToggle.configuration = config
        pinnedToggle.accessibilityLabel = config.title
        pinnedToggle.accessibilityValue = config.subtitle
        setNeedsQuickLayout()
    }
    private func draftSubtitle(_ draft: ConversationDraftPreview) -> String {
        let text = String(draft.text.prefix(256)).replacingOccurrences(of: "\n", with: " ")
        return String(format: Localization.text("chat.list.draftPreview"),
                      locale: Locale(identifier: Localization.localizationController.currentLocale.identifier),
                      text.isEmpty && draft.hasAttachments ? Localization.text("chat.list.draftAttachments") : text)
    }
    private func messageSubtitle(_ message: ChatMessage) -> String {
        message.revoked ? Localization.text("chat.live.revoked")
            : !message.isKnownContent ? Localization.text("chat.live.unknown")
            : message.kind == "system" ? ChatSystemNotice.text(message, userID: runtime.userID)
            : message.kind == "text" ? message.text : Localization.text("chat.live." + message.kind)
    }
    override func reloadRows() {
        summaryTask?.cancel()
        let generation = UUID()
        renderGeneration = generation
        let matches = runtime.visibleSortedConversations.filter {
            query.isEmpty || runtime.title($0).localizedStandardContains(query)
        }
        configurePinnedToggle(matches.filter { runtime.preference($0.id).isPinned })
        let displayed = matches.filter { !query.isEmpty || !runtime.pinnedConversationsCollapsed || !runtime.preference($0.id).isPinned }
        let now = Date()
        let locale = Locale(identifier: Localization.localizationController.currentLocale.identifier)
        let baseRows = displayed.map {
            let activity = runtime.listStates[$0.id]?.activityAt ?? 0
            let time = ConversationListTime(milliseconds: activity > 0 ? activity : $0.latestMessage?.createdAt,
                                            now: now, locale: locale)
            return LiveChatRow(
                id: $0.id, title: runtime.title($0),
                subtitle: runtime.draftPreviews[$0.id].map(draftSubtitle) ?? ($0.closed
                    ? Localization.text("chat.live.closed")
                    : ($0.readState.unread > 0
                        ? String($0.readState.unread) + " · " + Localization.text("chat.live.unread") : "")),
                symbol: $0.kind == "group" ? "person.3.fill" : "person.crop.circle.fill",
                badge: $0.readState.unread > 99 ? "99+" : $0.readState.unread > 0 ? String($0.readState.unread) : "",
                markers: runtime.preference($0.id).isMuted ? ["bell.slash.fill"] : [],
                isPinned: runtime.preference($0.id).isPinned,
                manuallyUnread: runtime.listStates[$0.id]?.manuallyUnread == true,
                isDraft: runtime.draftPreviews[$0.id] != nil,
                avatarUser: $0.kind == "direct" ? $0.members.first { $0.id != runtime.userID }?.id : nil,
                avatarAsset: $0.kind == "direct" ? $0.members.first { $0.id != runtime.userID }.flatMap { runtime.avatarAsset(user: $0.id, fallback: $0.profile) } : nil,
                timeText: time.text, timeAccessibilityText: time.accessibilityText)
        }
        // 同步状态通知到来时继续显示已读出的摘要；新摘要读取完成后再替换。
        rows = baseRows.map { row in
            var row = row
            if !row.isDraft, let message = summaryMessages[row.id] { row.subtitle = messageSubtitle(message) }
            return row
        }
        let state = ChatListContentState.resolve(
            hasSnapshot: runtime.hasSnapshot, synchronization: runtime.synchronization,
            storageFailure: runtime.failure != nil, totalCount: runtime.visibleSortedConversations.count,
            matchCount: matches.count, searching: !query.isEmpty)
        if state == .storageFailure { rows = []; summaryMessages = [:] }
        if state == .content {
            if list.backgroundView != nil { list.backgroundView = nil }
        } else {
            stateView.content.configure(state)
            list.backgroundView = stateView
        }
        let hasCachedContent = runtime.hasSnapshot || !runtime.conversations.isEmpty
        // 自动重试期间保留失败提示，成功后再移除，避免离线时每轮同步改变导航栏高度。
        switch runtime.synchronization {
        case .failed: synchronizationFailed = true
        case .synced, .idle: synchronizationFailed = false
        case .syncing: break
        }
        let prompt = runtime.failure == nil && hasCachedContent && synchronizationFailed
            ? Localization.text("chat.list.syncFailed") : nil
        if navigationItem.prompt != prompt { navigationItem.prompt = prompt }
        updateViewport()
        guard state != .storageFailure else { return }
        summaryTask = Task { [weak self] in
            guard let self, let store = runtime.engine?.store else { return }
            var values = baseRows
            var messages = summaryMessages
            for i in values.indices {
                guard !Task.isCancelled else { return }
                let id = values[i].id
                do {
                    messages[id] = try await store.latestVisibleMessage(id)
                } catch {
                    // 暂时读取失败保留已显示的摘要，成功读到 nil 才清除。
                }
                if !values[i].isDraft, let message = messages[id] { values[i].subtitle = messageSubtitle(message) }
            }
            guard !Task.isCancelled, renderGeneration == generation, runtime.engine?.store === store else { return }
            let visibleIDs = Set(values.map(\.id))
            summaryMessages = messages.filter { visibleIDs.contains($0.key) }
            rows = values
        }
    }
    deinit { summaryTask?.cancel(); NotificationCenter.default.removeObserver(self) }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("会话列表 · 折叠置顶") {
    AppNavigationController(rootViewController: ConversationListViewController(
        runtime: ConversationPreviewData.conversationListRuntime(collapsed: true)))
}
#endif
