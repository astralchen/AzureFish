import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

struct LiveMessageRow: Sendable, Hashable {
    let id: String
    let text: String
    let sender: String
    let status: String
    let outgoing: Bool
    let sequence: Int64
    var systemNotice = false
    var revoked = false
    var canReedit = false
}
final class LiveTextBubble: QuickLayoutView {
    let label = UILabel()
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        clipsToBounds = true
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout { label.resizable(axis: .horizontal).padding(12) }
}
final class LiveMessageCell: QuickLayoutCollectionViewCell {
    private let bubble = LiveTextBubble(), sender = UILabel(), status = UILabel()
    private var text: UILabel { bubble.label }
    private var outgoing = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        for label in [text, sender, status] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        text.font = .preferredFont(forTextStyle: .body)
        sender.font = .preferredFont(forTextStyle: .caption1)
        status.font = .preferredFont(forTextStyle: .caption2)
        sender.textColor = .secondaryLabel
        status.textColor = .secondaryLabel
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(spacing: 0) {
            if outgoing { Spacer() }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                if sender.text?.isEmpty == false { sender.resizable(axis: .horizontal) }
                bubble.resizable(axis: .horizontal)
                if status.text?.isEmpty == false { status.resizable(axis: .horizontal) }
            }.frame(maxWidth: min(420, max(160, contentView.bounds.width * 0.78)))
            if !outgoing { Spacer() }
        }.padding(.horizontal, 12).padding(.vertical, 4)
    }
    func configure(_ row: LiveMessageRow) {
        outgoing = row.outgoing
        text.text = row.text
        sender.text = row.sender
        status.text = row.status
        text.textColor = outgoing ? .white : .label
        bubble.backgroundColor = outgoing ? .systemBlue : .secondarySystemBackground
        bubble.setNeedsQuickLayout()
        setNeedsQuickLayout()
    }
}
/// iOS 15 起的真实消息时间线；布局变化保留列表和输入控件实例。
final class LiveConversationViewController: LocalizedQuickLayoutHostingController,
    UITextViewDelegate,
    UICollectionViewDelegate
{
    let runtime: ChatRuntime
    var conversation: ChatConversation
    let list = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
    private lazy var adapter = CollectionListAdapter<String>(collectionView: list)
    let editor = UITextView()
    let sendButton = UIButton(type: .system), attachmentButton = UIButton(type: .system),
        voiceButton = UIButton(type: .system)
    private let historyButton = UIButton(type: .system), latestButton = UIButton(type: .system),
        notice = UILabel()
    private var rows: [LiveMessageRow] = []
    private var messages: [ChatMessage] = []
    private var pending: [ChatPendingMessage] = []
    private var uploads: [ChatUploadBatch] = []
    private var actuallyRead = Set<Int64>()
    private var revokeIDs: [String: UUID] = [:]
    private var page: ChatHistory?
    private var observer: UUID?
    private var loading = false, initial = true, restoringDraft = false
    private var draftTask: Task<Void, Never>?
    private var reeditExpiryTask: Task<Void, Never>?
    private var reediting = false
    private var revoking = Set<String>()
    private var confirmedRevocations: [String: ChatMessage] = [:]
    private var reloadGeneration = 0
    var attachments: [ChatUploadItem] = [] {
        didSet {
            let value = attachments
            let store = runtime.engine?.store
            let id = conversation.id
            Task { try? await store?.setMeta(value, id: "attachments:" + id) }
            attachmentButton.accessibilityValue = String(value.count)
        }
    }
    var mediaCoordinator: LiveMediaCoordinator?
    init(runtime: ChatRuntime, conversation: ChatConversation) {
        self.runtime = runtime
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(spacing: 4) {
            notice.resizable(axis: .horizontal).padding(.horizontal, 16)
            historyButton.frame(minHeight: 44)
            list.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
            if !latestButton.isHidden { latestButton.frame(minHeight: 44) }
            HStack(alignment: .bottom, spacing: 8) {
                attachmentButton.frame(width: 44, height: 44)
                editor.resizable().frame(minHeight: 44, maxHeight: 130).frame(maxWidth: .infinity)
                voiceButton.frame(width: 44, height: 44)
                sendButton.frame(width: 44, height: 44)
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }.safeAreaPadding(.all, 0)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        quickLayoutKeyboardSafeAreaBehavior = .docked()
        list.backgroundColor = .clear
        list.contentInsetAdjustmentBehavior = .never
        list.keyboardDismissMode = .interactive
        list.collectionViewLayout = adapter.makeCompositionalLayout()
        adapter.collectionDelegate = self
        editor.font = .preferredFont(forTextStyle: .body)
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = .secondarySystemBackground
        editor.layer.cornerRadius = 18
        editor.delegate = self
        editor.accessibilityIdentifier = "chat.composer"
        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.numberOfLines = 0
        notice.textColor = .secondaryLabel
        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill"), for: .normal)
        attachmentButton.setImage(UIImage(systemName: "plus"), for: .normal)
        voiceButton.setImage(UIImage(systemName: "mic"), for: .normal)
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)
        attachmentButton.addAction(
            UIAction { [weak self] _ in self?.mediaCoordinator?.choose() }, for: .touchUpInside)
        voiceButton.addAction(
            UIAction { [weak self] _ in self?.mediaCoordinator?.record() }, for: .touchUpInside)
        historyButton.addAction(
            UIAction { [weak self] _ in self?.loadHistory() }, for: .touchUpInside)
        latestButton.addAction(
            UIAction { [weak self] _ in self?.scrollLatest() }, for: .touchUpInside)
        latestButton.isHidden = true
        let current = conversation
        ConversationDetailsNavigation.install(on: self, runtime: runtime, conversation: { [weak self] in self?.conversation ?? current }) { [weak self] message in
            guard let self, let engine = runtime.engine,
                  try await engine.store.visibleMessage(message.id, conversation: conversation.id) != nil,
                  runtime.engine === engine else { throw ChatStoreError.unavailable }
            contextAnchor = message.id
            focusMessage = message.id
            reloadMessages()
        }
        mediaCoordinator = LiveMediaCoordinator(controller: self)
        observer = runtime.observe { [weak self] in self?.reloadMessages() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAfterForeground),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        reloadLocalizedContent()
        loadHistory()
        Task { [weak self] in
            guard let self, let store = runtime.engine?.store else { return }
            if let draft = try? await store.draft(conversation.id) {
                restoringDraft = true
                editor.text = draft.text
                restoringDraft = false
                if let saved: [ChatUploadItem] = try? await store.meta(
                    "attachments:" + conversation.id)
                {
                    attachments = saved
                }
                setNeedsQuickLayout()
            }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        runtime.enteredConversation(conversation.id)
        reloadMessages()
        markVisibleRead()
    }
    @objc private func refreshAfterForeground() { reloadMessages() }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        title = runtime.title(conversation)
        historyButton.setTitle(Localization.text("chat.live.history"), for: .normal)
        latestButton.setTitle(Localization.text("chat.live.latest"), for: .normal)
        sendButton.accessibilityLabel = Localization.text("chat.live.sendMessage")
        attachmentButton.accessibilityLabel = Localization.text("chat.live.attach")
        voiceButton.accessibilityLabel = Localization.text("chat.live.record")
        reloadMessages()
    }
    func textViewDidChange(_ textView: UITextView) {
        setNeedsQuickLayout()
        guard !restoringDraft else { return }
        draftTask?.cancel()
        let value = textView.text ?? ""
        let id = conversation.id
        let store = runtime.engine?.store
        draftTask = Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                try await store?.saveDraft(.init(text: value), conversation: id)
            } catch {}
        }
    }
    var conversationID: String { conversation.id }
    private var contextAnchor: String?
    private var focusMessage: String?
    private var focusLatestAfterLoad = false
    private func reloadMessages() {
        guard isViewLoaded, let engine = runtime.engine else { return }
        reloadGeneration += 1
        let generation = reloadGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                if let current = runtime.conversations.first(where: { $0.id == conversation.id }) {
                    conversation = current
                }
                let wasAtEnd =
                    initial
                    || list.contentSize.height - list.contentOffset.y - list.bounds.height < 80
                let previousLast = messages.last?.id
                let loaded: [ChatMessage]
                if let contextAnchor { loaded = try await engine.store.messageContext(contextAnchor, conversation: conversation.id) }
                else { loaded = try await engine.store.messages(conversation.id, limit: 200) }
                let availability = try await engine.store.reeditAvailability(
                    conversation: conversation.id)
                guard runtime.engine === engine, generation == reloadGeneration else { return }
                messages = loaded.map { message in
                    if message.revoked { confirmedRevocations[message.id] = nil }
                    return confirmedRevocations[message.id] ?? message
                }
                scheduleReeditExpiry(availability.map(\.expiresAt).min())
                uploads = try await engine.store.transfers(as: ChatUploadBatch.self).filter {
                    $0.conversation == conversation.id
                }.sorted { $0.createdAt < $1.createdAt }
                pending = try await engine.store.pending().filter {
                    $0.outgoing.conversationID == conversation.id
                }
                rows =
                    messages.map { message in
                        let outgoing = message.senderID == runtime.userID
                        let sender =
                            conversation.kind == "group" && !outgoing
                            ? runtime.contacts.first(where: { $0.peer.id == message.senderID })?
                                .peer.nickname
                                ?? conversation.members.first(where: { $0.id == message.senderID })?
                                .profile.nickname
                                ?? Localization.text("chat.live.groupMember") : ""
                        let state =
                            message.receipt.read == message.receipt.expected
                                && message.receipt.expected > 0
                            ? "read"
                            : message.receipt.delivered == message.receipt.expected
                                && message.receipt.expected > 0
                                ? "delivered" : "sent"
                        let text =
                            message.revoked
                            ? revokedNotice(message)
                            : message.kind == "system" ? ChatSystemNotice.text(message, userID: runtime.userID)
                            : ["text", "link"].contains(message.kind)
                                ? message.text
                                : message.assets.flatMap(\.resources).filter {
                                    $0.role == "original"
                                }.map(\.filename)
                                    .joined(separator: "\n")
                        return LiveMessageRow(
                            id: message.id, text: text, sender: sender,
                            status: outgoing && !message.revoked
                                ? Localization.text("chat.live." + state) : "", outgoing: outgoing,
                            sequence: message.sequence, systemNotice: message.kind == "system", revoked: message.revoked,
                            canReedit: message.revoked && outgoing && message.kind == "text"
                                && runtime.canSend(conversation)
                                && availability.contains { $0.messageID == message.id })
                    }
                    + pending.map {
                        LiveMessageRow(
                            id: $0.outgoing.id.uuidString.lowercased(),
                            text: $0.outgoing.text.isEmpty
                                ? Localization.text("chat.live.media_group") : $0.outgoing.text,
                            sender: "",
                            status: Localization.text("chat.live." + $0.state), outgoing: true,
                            sequence: 0)
                    }
                rows += uploads.map { batch in
                    let total = batch.items.flatMap(\.resources).reduce(Int64(0)) {
                        $0 + $1.input.bytes
                    }
                    let percent = total > 0 ? min(100, batch.completedBytes * 100 / total) : 0
                    return LiveMessageRow(
                        id: batch.id.uuidString,
                        text: batch.items.compactMap { $0.resources.first?.input.filename }.joined(
                            separator: "\n"),
                        sender: "",
                        status: Localization.text(
                            "chat.live." + (batch.cancelRequested ? "cancelling" : batch.state))
                            + (batch.state == "uploading" ? " · \(percent)%" : ""), outgoing: true,
                        sequence: 0)
                }
                render()
                guard runtime.engine === engine, generation == reloadGeneration else { return }
                let allowed = runtime.canSend(conversation) && !reediting
                editor.isEditable = allowed
                sendButton.isEnabled = allowed
                attachmentButton.isEnabled = allowed
                voiceButton.isEnabled = allowed
                notice.text =
                    !allowed
                    ? Localization.text(
                        conversation.closed ? "chat.live.closed" : "chat.live.friendRequired")
                    : runtime.online ? nil : Localization.text("chat.live.offline")
                historyButton.isHidden = contextAnchor != nil
                if contextAnchor != nil {
                    latestButton.isHidden = false
                } else if wasAtEnd {
                    scrollLatest()
                } else if previousLast != messages.last?.id {
                    latestButton.isHidden = false
                }
                initial = false
                setNeedsQuickLayout()
                markVisibleRead()
            } catch { showFailure() }
        }
    }
    private func render() {
        let values = rows
        adapter.apply(transaction: .disabled, completion: { [weak self] _ in
            guard let self else { return }
            if focusLatestAfterLoad, contextAnchor == nil {
                focusLatestAfterLoad = false
                scrollLatest()
                return
            }
            guard let id = focusMessage, let index = rows.firstIndex(where: { $0.id == id }) else { return }
            focusMessage = nil
            list.layoutIfNeeded()
            let path = IndexPath(item: index, section: 0)
            list.scrollToItem(at: path, at: .centeredVertically, animated: false)
            list.layoutIfNeeded()
            if let cell = list.cellForItem(at: path) {
                let highlight = UIView(frame: cell.contentView.bounds)
                highlight.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                highlight.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.25)
                highlight.isUserInteractionEnabled = false
                cell.contentView.addSubview(highlight)
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 1.5, animations: { highlight.alpha = 0 }) { _ in highlight.removeFromSuperview() }
                UIAccessibility.post(notification: .layoutChanged, argument: cell)
            }
        }) {
            ListSection("timeline") {
                ListKit.ForEach(values, id: \.id) { row in
                    if row.revoked || row.systemNotice {
                        Row(row.id, model: row, cell: LiveRevokedMessageCell.self) {
                            [weak self] cell, row, _ in
                            cell.configure(
                                text: row.text, editTitle: Localization.text("chat.live.reedit"),
                                edit: row.canReedit
                                    ? { [weak self] in self?.beginReedit(row.id) } : nil)
                        }
                        .refreshID(row).refresh(
                            when: .automatic, action: .reconfigure(layout: .invalidate)
                        )
                        .contextMenu { [weak self] _ in
                            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                                [weak self] _ in self?.messageMenu(row.id)
                            }
                        }
                    } else {
                        Row(row.id, model: row, cell: LiveMessageCell.self) { cell, row, _ in
                            cell.configure(row)
                        }
                        .refreshID(row).refresh(
                            when: .automatic, action: .reconfigure(layout: .invalidate)
                        )
                        .onSelect { [weak self] _, _ in self?.openMessage(row.id) }
                        .contextMenu { [weak self] _ in
                            UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                                [weak self] _ in
                                self?.messageMenu(row.id)
                            }
                        }
                    }
                }
            }.layout(
                ListCustomSectionLayout(id: "timeline") { _, _, _ in
                    let size = NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
                    return NSCollectionLayoutSection(
                        group: NSCollectionLayoutGroup.horizontal(
                            layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
                })
        }
    }
    private func loadHistory() {
        guard !loading, let engine = runtime.engine else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            defer { loading = false }
            do {
                let result = try await engine.history(
                    conversation.id, before: page?.before ?? 0, upper: page?.upper ?? 0,
                    boundary: page?.boundary ?? 0)
                page = result
                historyButton.isHidden = !result.hasMore
                reloadMessages()
            } catch { showFailure() }
        }
    }
    private var submitting = false
    private func send() {
        guard !submitting, !reediting, runtime.canSend(conversation), let engine = runtime.engine,
            let manager = runtime.session.sessionManager
        else { return }
        let text = editor.text ?? ""
        let selected = attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected.isEmpty
        else { return }
        contextAnchor = nil
        submitting = true
        draftTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            defer { submitting = false }
            do {
                let credentials = try await manager.localIdentity()
                var batches: [ChatUploadBatch] = []
                var group: [ChatUploadItem] = []
                @MainActor func flushGroup() {
                    if !group.isEmpty {
                        batches.append(
                            .init(
                                conversation: conversation.id, kind: "media_group", items: group,
                                deviceID: credentials.deviceID))
                        group = []
                    }
                }
                for item in selected {
                    if ["audio", "file"].contains(item.kind) {
                        flushGroup()
                        batches.append(
                            .init(
                                conversation: conversation.id, kind: item.kind, items: [item],
                                deviceID: credentials.deviceID))
                    } else {
                        group.append(item)
                    }
                }
                flushGroup()
                if !selected.isEmpty {
                    let limits = try await MediaAPI(session: manager).capabilities()
                    for batch in batches {
                        guard batch.items.count <= limits.groupItems,
                            batch.items.flatMap(\.resources).reduce(
                                Int64(0), { $0 + $1.input.bytes })
                                <= limits.groupBytes
                        else { throw APIClientError.requestTooLarge }
                    }
                }
                let outgoing =
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : ChatOutgoing(
                        conversationID: conversation.id, deviceID: credentials.deviceID, text: text)
                try await engine.store.enqueueComposition(
                    text: outgoing, batches: batches, conversation: conversation.id)
                if editor.text == text { editor.text = "" }
                let sentIDs = Set(selected.map(\.id))
                attachments.removeAll { sentIDs.contains($0.id) }
                try await engine.store.saveDraft(
                    .init(text: editor.text ?? ""), conversation: conversation.id)
                setNeedsQuickLayout()
                await engine.changed()
                await engine.flush()
                await runtime.transfers?.resume()
            } catch { showFailure() }
        }
    }
    private func scrollLatest() {
        if contextAnchor != nil { contextAnchor = nil; focusLatestAfterLoad = true; reloadMessages(); return }
        guard !rows.isEmpty else { return }
        list.layoutIfNeeded()
        list.scrollToItem(
            at: IndexPath(item: rows.count - 1, section: 0), at: .bottom, animated: false)
        latestButton.isHidden = true
        setNeedsQuickLayout()
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { markVisibleRead() }
    private func markVisibleRead() {
        guard viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active,
            !list.isDragging, !list.isDecelerating, let engine = runtime.engine
        else { return }
        for path in list.indexPathsForVisibleItems where rows.indices.contains(path.item) {
            guard let frame = list.layoutAttributesForItem(at: path)?.frame,
                list.bounds.intersection(frame).height >= min(frame.height, 44),
                rows[path.item].sequence > 0
            else { continue }
            actuallyRead.insert(rows[path.item].sequence)
        }
        var through = conversation.readState.read
        while actuallyRead.contains(through + 1) { through += 1 }
        guard through > conversation.readState.read else { return }
        Task { try? await engine.markRead(conversation, visibleThrough: through) }
    }
    private func messageMenu(_ id: String) -> UIMenu {
        var actions: [UIAction] = []
        if let message = messages.first(where: { $0.id == id }) {
            if message.kind == "text" && !message.revoked {
                actions.append(
                    UIAction(
                        title: Localization.text("chat.live.copy"),
                        image: UIImage(systemName: "doc.on.doc")
                    ) {
                        _ in UIPasteboard.general.string = message.text
                    })
            }
            actions.append(
                UIAction(
                    title: Localization.text("chat.live.localDelete"), attributes: .destructive
                ) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        try? await runtime.engine?.store.hide(message: id)
                        reloadMessages()
                    }
                })
            if message.senderID == runtime.userID && !message.revoked
                && Date().timeIntervalSince1970 * 1000 < Double(message.createdAt + 120000)
            {
                actions.append(
                    UIAction(title: Localization.text("chat.live.revoke"), attributes: .destructive)
                    { [weak self] _ in
                        self?.revoke(message)
                    })
            }
            if !message.assets.isEmpty {
                actions.append(
                    UIAction(title: Localization.text("chat.live.open")) { [weak self] _ in
                        self?.openMessage(id)
                    })
            }
        } else if let value = pending.first(where: { $0.outgoing.id.uuidString.lowercased() == id })
        {
            actions.append(
                UIAction(title: Localization.text("chat.live.retry")) { [weak self] _ in
                    Task { try? await self?.runtime.engine?.retry(value) }
                })
        }
        if let batch = uploads.first(where: { $0.id.uuidString == id }) {
            if batch.state == "failed" || batch.state == "waiting" {
                actions.append(
                    UIAction(title: Localization.text("chat.live.retry")) { [weak self] _ in
                        Task { try? await self?.runtime.transfers?.retry(batch.id) }
                    })
            }
            actions.append(
                UIAction(title: Localization.text("chat.live.cancel"), attributes: .destructive) {
                    [weak self] _ in
                    Task { try? await self?.runtime.transfers?.cancel(batch.id) }
                })
        }
        return UIMenu(children: actions)
    }
    private func revoke(_ message: ChatMessage) {
        guard !revoking.contains(message.id), let engine = runtime.engine else { return }
        revoking.insert(message.id)
        let id = revokeIDs[message.id] ?? UUID()
        revokeIDs[message.id] = id
        Task {
            defer { revoking.remove(message.id) }
            do {
                let result = try await engine.revoke(message, fallbackOperationID: id)
                guard runtime.engine === engine else { return }
                confirmedRevocations[message.id] = result.message
                if let index = rows.firstIndex(where: { $0.id == message.id }) {
                    rows[index] = LiveMessageRow(
                        id: message.id, text: revokedNotice(result.message), sender: "", status: "",
                        outgoing: true, sequence: message.sequence, revoked: true,
                        canReedit: result.canReedit && runtime.canSend(conversation))
                    render()
                }
                reloadMessages()
                if message.kind == "text", !result.canReedit {
                    showReeditNotice("chat.live.revokeNoRecovery")
                }
            } catch {
                guard runtime.engine === engine else { return }
                if case APIClientError.service(let failure) = error, (400..<500).contains(failure.statusCode),
                    ![401, 408, 409, 429].contains(failure.statusCode) || failure.code == .revokeWindowExpired {
                    showReeditNotice("chat.live.revokeFailed")
                } else {
                    showReeditNotice("chat.live.revokeConfirming")
                    runtime.refresh()
                }
            }
        }
    }
    private func revokedNotice(_ message: ChatMessage) -> String {
        if message.senderID == runtime.userID { return Localization.text("chat.live.revokedSelf") }
        guard conversation.kind == "group" else {
            return Localization.text("chat.live.revokedOther")
        }
        let name =
            runtime.contacts.first(where: { $0.peer.id == message.senderID })?.peer.nickname
            ?? conversation.members.first(where: { $0.id == message.senderID })?.profile.nickname
            ?? Localization.text("chat.live.groupMember")
        return Localization.text("chat.live.revokedMember", name.isEmpty ? Localization.text("chat.live.groupMember") : name)
    }
    private func scheduleReeditExpiry(_ deadline: Date?) {
        reeditExpiryTask?.cancel()
        guard let deadline else { return }
        reeditExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000))
            } catch { return }
            self?.reloadMessages()
        }
    }
    private func beginReedit(_ id: String) {
        guard !reediting, !submitting, presentedViewController == nil,
            runtime.canSend(conversation), let engine = runtime.engine
        else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let original = try await engine.store.reeditText(
                    message: id, conversation: conversation.id)
                guard runtime.engine === engine, runtime.canSend(conversation), !reediting,
                    !submitting, presentedViewController == nil
                else { return }
                let existing = editor.text ?? ""
                if !existing.isEmpty, existing != original {
                    let alert = UIAlertController(
                        title: Localization.text("chat.live.replaceDraftTitle"),
                        message: Localization.text("chat.live.replaceDraftBody"),
                        preferredStyle: .alert)
                    alert.addAction(
                        UIAlertAction(title: Localization.text("chat.live.cancel"), style: .cancel))
                    alert.addAction(
                        UIAlertAction(
                            title: Localization.text("chat.live.replaceDraft"), style: .destructive
                        ) { [weak self] _ in
                            self?.commitReedit(id, expectedText: existing, engine: engine)
                        })
                    present(alert, animated: true)
                } else {
                    commitReedit(id, expectedText: existing, engine: engine)
                }
            } catch {
                guard runtime.engine === engine else { return }
                showReeditNotice(
                    error as? ChatStoreError == .reeditExpired
                        ? "chat.live.reeditExpired" : "chat.live.reeditUnavailable")
                reloadMessages()
            }
        }
    }
    private func commitReedit(_ id: String, expectedText: String, engine: ChatEngine) {
        guard runtime.engine === engine, runtime.canSend(conversation), !reediting, !submitting,
            editor.text == expectedText
        else { return }
        reediting = true
        editor.isEditable = false
        sendButton.isEnabled = false
        attachmentButton.isEnabled = false
        voiceButton.isEnabled = false
        let previous = draftTask
        draftTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            defer {
                reediting = false
                if runtime.engine === engine { reloadMessages() }
            }
            await previous?.value
            var before: ChatLocalDraft?
            do {
                guard runtime.engine === engine, runtime.canSend(conversation),
                    editor.text == expectedText
                else { return }
                var draft = try await engine.store.draft(conversation.id)
                draft.text = expectedText
                before = draft
                try await engine.store.saveDraft(draft, conversation: conversation.id)
                guard runtime.engine === engine, runtime.canSend(conversation) else { return }
                let restored = try await engine.store.restoreReeditedDraft(
                    message: id, conversation: conversation.id, expectedText: expectedText)
                guard runtime.engine === engine, runtime.canSend(conversation),
                    editor.text == expectedText
                else {
                    if let before {
                        try? await engine.store.saveDraft(before, conversation: conversation.id)
                    }
                    return
                }
                editor.text = restored.text
                editor.isEditable = true
                editor.becomeFirstResponder()
                editor.selectedRange = NSRange(
                    location: (restored.text as NSString).length, length: 0)
                setNeedsQuickLayout()
                UIAccessibility.post(notification: .layoutChanged, argument: editor)
            } catch {
                guard runtime.engine === engine else { return }
                showReeditNotice(
                    error as? ChatStoreError == .reeditExpired
                        ? "chat.live.reeditExpired" : "chat.live.reeditUnavailable")
            }
        }
    }
    private func showReeditNotice(_ key: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: Localization.text(key), message: nil, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: Localization.text("account.design.done"), style: .cancel))
        present(alert, animated: true)
    }
    private func openMessage(_ id: String) {
        if uploads.contains(where: { $0.id.uuidString == id }) {
            let sheet = UIAlertController(
                title: Localization.text("chat.live.transfer"), message: nil,
                preferredStyle: .actionSheet)
            for action in messageMenu(id).children.compactMap({ $0 as? UIAction }) {
                if action.attributes.contains(.destructive) {
                    sheet.addAction(
                        UIAlertAction(title: action.title, style: .destructive) { [weak self] _ in
                            guard let uuid = UUID(uuidString: id) else { return }
                            Task { try? await self?.runtime.transfers?.cancel(uuid) }
                        })
                } else {
                    sheet.addAction(
                        UIAlertAction(title: action.title, style: .default) { [weak self] _ in
                            guard let uuid = UUID(uuidString: id) else { return }
                            Task { try? await self?.runtime.transfers?.retry(uuid) }
                        })
                }
            }
            sheet.addAction(
                UIAlertAction(title: Localization.text("account.design.done"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = list
            present(sheet, animated: true)
            return
        }
        guard let message = messages.first(where: { $0.id == id }), !message.revoked else { return }
        mediaCoordinator?.open(message)
    }
    func showFailure() {
        let alert = UIAlertController(
            title: Localization.text("chat.live.failed"), message: nil, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }
    deinit {
        draftTask?.cancel()
        reeditExpiryTask?.cancel()
        if let observer {
            let runtime = runtime
            Task { @MainActor in runtime.remove(observer) }
        }
        NotificationCenter.default.removeObserver(self)
    }
}
#if DEBUG
    @available(iOS 17.0, *)
    #Preview("聊天气泡") {
        let cell = LiveMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        cell.configure(
            .init(
                id: "preview", text: "周末去海边走走吗？", sender: "林沐", status: "", outgoing: false,
                sequence: 1))
        return cell
    }
#endif
