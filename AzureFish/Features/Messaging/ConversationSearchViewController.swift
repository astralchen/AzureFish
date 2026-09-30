import AppLocalization
import AzureFishAPI
import AzureFishChat
import UIKit

/// 当前会话的本地文字搜索；点击结果先验证消息，再交由原聊天页定位。
final class ConversationSearchViewController: LiveChatListController {
    private let conversation: ChatConversation
    private let locate: (ChatMessage) async throws -> Void
    private var results: [ChatMessage] = []
    private var cursor: ChatSearchCursor?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var loading = false
    var conversationID: String { conversation.id }
    init(runtime: ChatRuntime, conversation: ChatConversation, locate: @escaping (ChatMessage) async throws -> Void) {
        self.conversation = conversation; self.locate = locate
        super.init(runtime: runtime)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { "chat.details.search" }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        definesPresentationContext = true
        navigationItem.searchController?.hidesNavigationBarDuringPresentation = false
        if #available(iOS 16.0, *) { navigationItem.preferredSearchBarPlacement = .stacked }
        navigationItem.prompt = Localization.text("chat.details.searchHelp")
        list.accessibilityIdentifier = "chat.search.results"
        selected = { [weak self] id in self?.select(id) }
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        navigationItem.prompt = Localization.text("chat.details.searchHelp")
    }
    override func reloadRows() { search(append: false) }
    private func search(append: Bool) {
        guard isViewLoaded else { return }
        task?.cancel()
        let token = UUID(); generation = token
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !append { results = []; cursor = nil; rows = []; loading = false }
        guard !text.isEmpty, let engine = runtime.engine else { status("chat.details.searchHelp"); return }
        loading = true
        status("account.design.loading")
        let before = append ? cursor : nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if !append { try await Task.sleep(nanoseconds: 250_000_000) }
                let page = try await engine.store.searchMessages(conversation: conversation.id, query: text, before: before)
                try Task.checkCancellation()
                guard generation == token, runtime.engine === engine else { return }
                results += page.messages; cursor = page.next; loading = false
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: Localization.localizationController.currentLocale.identifier)
                formatter.dateStyle = .medium; formatter.timeStyle = .short
                rows = results.map { message in
                    let name = conversation.members.first { $0.id == message.senderID }.map { runtime.memberName($0) } ?? Localization.text("chat.live.groupMember")
                    let term = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? text
                    return LiveChatRow(id: message.id, title: Self.snippet(message.text, term: term),
                        subtitle: name + " · " + formatter.string(from: Date(timeIntervalSince1970: Double(message.createdAt) / 1000)), symbol: "text.bubble", highlight: term)
                }
                if cursor != nil { rows.append(.init(id: "more", title: Localization.text("chat.details.moreResults"), symbol: "chevron.down")) }
                status(results.isEmpty ? "chat.list.noResults" : nil)
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                loading = false; status("chat.live.failed")
                showError(error)
            }
        }
    }
    private static func snippet(_ text: String, term: String) -> String {
        let match = text.range(of: term, options: .caseInsensitive)?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }
    private func status(_ key: String?) {
        guard let key else { list.backgroundView = nil; return }
        let label = UILabel(); label.text = Localization.text(key); label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body); label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0; label.textAlignment = .center
        list.backgroundView = rows.isEmpty ? label : nil
    }
    private func select(_ id: String) {
        if id == "more" { if !loading { search(append: true) }; return }
        guard results.contains(where: { $0.id == id }), let engine = runtime.engine else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let current = try await engine.store.visibleMessage(id, conversation: conversation.id), runtime.engine === engine else { throw ChatStoreError.unavailable }
                try await locate(current)
            } catch {
                search(append: false)
                let alert = UIAlertController(title: Localization.text("chat.details.messageUnavailable"), message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .cancel))
                if presentedViewController == nil { present(alert, animated: true) }
            }
        }
    }
    deinit { task?.cancel() }
}

/// 两种聊天页面共用详情导航，连续点击不会重复入栈。
@MainActor
enum ConversationDetailsNavigation {
    static func install(on controller: UIViewController, runtime: ChatRuntime,
                        conversation: @escaping () -> ChatConversation,
                        locate: @escaping (ChatMessage) async throws -> Void) {
        let button = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), primaryAction: UIAction { [weak controller] _ in
            guard let controller, let navigation = controller.navigationController,
                  navigation.topViewController === controller, navigation.transitionCoordinator == nil else { return }
            let page = ConversationDetailsViewController(runtime: runtime, conversation: conversation()) { [weak controller] message in
                guard let controller, let navigation = controller.navigationController else { throw ChatStoreError.unavailable }
                try await locate(message)
                navigation.popToViewController(controller, animated: true)
            }
            navigation.pushViewController(page, animated: true)
        })
        button.accessibilityIdentifier = "chat.details.open"
        button.accessibilityLabel = Localization.text("chat.live.details")
        controller.navigationItem.rightBarButtonItem = button
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("聊天记录搜索") {
    AppNavigationController(rootViewController: ConversationSearchViewController(runtime: ConversationPreviewData.detailsRuntime(), conversation: ConversationPreviewData.detailsConversation(), locate: { _ in }))
}
#endif
