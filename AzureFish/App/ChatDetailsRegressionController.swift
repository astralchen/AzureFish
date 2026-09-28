#if DEBUG
import AzureFishAPI
import AzureFishChat
import CryptoKit
import UIKit

private actor DetailsEmptySession: APISessionStore {
    func load(environmentID: String) async throws -> APISessionRecord? { nil }
    func save(_ record: APISessionRecord, environmentID: String) async throws {}
    func clear(environmentID: String) async throws {}
}

/// 使用随机密钥及虚构本地资料验证真实详情、搜索和草稿导航；不启动网络同步。
@available(iOS 26.0, *)
final class ChatDetailsRegressionController: UIViewController {
    private var runtime: ChatRuntime?
    private var root: URL?
    private var task: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        // 隔离 UI 回归不等待系统搜索动画的空闲通知；正式页面不改变系统动画。
        if !ProcessInfo.processInfo.arguments.contains("-contacts-list") { UIView.setAnimationsEnabled(false) }
        view.backgroundColor = .systemBackground
        title = "详情回归"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDetails-" + UUID().uuidString)
                self.root = root
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let preview = ConversationPreviewData.detailsRuntime()
                let user = UUID(uuidString: preview.userID)!
                let store = try ChatStore(url: root.appendingPathComponent("db"), key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "details-test", userID: user)
                let media = try ChatMediaStore(root: root.appendingPathComponent("media"), key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, environment: "details-test", userID: user)
                let environment = try APIEnvironment(identifier: "details-test", baseURL: URL(string: "https://example.invalid")!)
                let engine = ChatEngine(store: store, session: APISessionManager(api: AccountAPI(environment: environment), store: DetailsEmptySession()))
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-details-large") { navigationController?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
                let conversation = ConversationPreviewData.detailsConversation(group: !args.contains("-details-direct"), owner: !args.contains("-details-member"))
                try await store.save(conversation)
                for offset in 0..<(args.contains("-contacts-list") ? 0 : 260) {
                    let i = offset + 1
                    let object: [String: Any] = ["id": "fixture-\(i)", "conversationID": conversation.id, "clientID": "", "serverID": "fixture-\(i)",
                        "senderID": conversation.members[1].id, "deviceID": "fixture", "sequence": i, "createdAt": 1_800_000_000_000 + i * 1000,
                        "revision": 1, "kind": "text", "schemaVersion": 1, "text": i == 2 ? "海边见面 old needle العربية" : "周末计划 \(i)", "revoked": false, "assets": [],
                        "receipt": ["expected": 0, "delivered": 0, "read": 0, "revision": 0]]
                    try await store.save(JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object)))
                }
                try await store.saveDraft(.init(text: "保留这条草稿"), conversation: conversation.id)
                var conversations = [conversation]
                if args.contains("-details-list") {
                    var direct = ConversationPreviewData.detailsConversation(group: false)
                    direct.readState.unread = 12
                    try await store.save(direct)
                    var message = try await store.messages(conversation.id).last!
                    message.id = "list-direct-message"; message.conversationID = direct.id
                    try await store.save(message)
                    var empty = direct; empty.id = "list-empty"; empty.latest = 0; empty.latestMessage = nil
                    empty.readState.unread = 0
                    try await store.save(empty)
                    conversations += [direct, empty]
                }
                let contacts = args.contains("-contacts-list") ? ConversationPreviewData.contacts : []
                for contact in contacts { try await store.save(contact) }
                let runtime = ChatRuntime(session: preview.session, engine: engine, media: media, conversations: conversations, pageLeaseRoot: root, contacts: contacts)
                self.runtime = runtime
                try await runtime.refreshListStates()
                if args.contains("-details-dark") { navigationController?.overrideUserInterfaceStyle = .dark }
                if args.contains("-contacts-list") {
                    navigationController?.overrideUserInterfaceStyle = args.contains("-details-dark") ? .dark : .light
                    let tabs = UITabBarController()
                    let contacts = ContactsSplitViewController(runtime: runtime)
                    contacts.tabBarItem = UITabBarItem(title: Localization.text("chat.live.contacts"), image: UIImage(systemName: "person.2"), tag: 0)
                    let settings = UINavigationController(rootViewController: AccountSettingsViewController(runtime: runtime))
                    settings.tabBarItem = UITabBarItem(title: Localization.text("account.design.settings"), image: UIImage(systemName: "gearshape"), tag: 1)
                    tabs.viewControllers = [contacts, settings]
                    navigationController?.setNavigationBarHidden(true, animated: false)
                    navigationController?.pushViewController(tabs, animated: false)
                    return
                }
                if args.contains("-details-list") {
                    navigationController?.overrideUserInterfaceStyle = args.contains("-details-dark") ? .dark : .light
                    try await runtime.setPreference(.init(isPinned: true), conversation: conversation.id)
                    navigationController?.pushViewController(ConversationListViewController(runtime: runtime), animated: false)
                    return
                }
                let chat: UIViewController = args.contains("-details-legacy")
                    ? LiveConversationViewController(runtime: runtime, conversation: conversation)
                    : ConversationPageFactory.make(runtime: runtime, conversation: conversation)
                navigationController?.pushViewController(chat, animated: false)
            } catch {
                let label = UILabel(); label.text = "Fixture unavailable"; label.frame = view.bounds; view.addSubview(label)
            }
        }
    }
    isolated deinit {
        task?.cancel(); runtime?.stop()
        if let root { try? FileManager.default.removeItem(at: root) }
    }
}
@available(iOS 26.0, *)
#Preview("详情交互回归") { UINavigationController(rootViewController: ChatDetailsRegressionController()) }
#endif
