import AzureFishAPI
import AzureFishChat
import UIKit
import QuickLayoutKit

/// 将账号时间线适配到原版聊天页面；演示消息、模拟回执与回复不进入此路径。
@MainActor
@available(iOS 26.0, *)
final class LiveChatSession: ChatSessionProviding {
    let runtime: ChatRuntime
    var conversation: ChatConversation
    weak var controller: ChatViewController?
    var messages: [ChatMessage] = []
    var pending: [ChatPendingMessage] = []
    var uploads: [ChatUploadBatch] = []
    var identities: [String: Int] = [:]
    var sourceIDs: [Int: String] = [:]
    var contents: [String: MessageContent] = [:]
    var observer: UUID?
    var reloadTask: Task<Void, Never>?
    var historyTask: Task<Void, Never>?
    var clockTask: Task<Void, Never>?
    var readTask: Task<Void, Never>?
    var mediaTasks: [String: Task<Void, Never>] = [:]
    var mediaFailures = Set<String>()
    var mediaStores: [String: PageAttachmentStore] = [:]
    var operations: [UUID: Task<Void, Never>] = [:]
    var page: ChatHistory?
    var historyLimit = 200
    var contextAnchor: String?
    private var focusLatestAfterLoad = false
    var reeditable = Set<String>()
    var visible = Set<Int64>()
    var stopped = false
    var hasRendered = false
    var loadingHistory = false
    var revokeIDs: [String: UUID] = [:]
    var nextDeadline: Date?
    var pendingReason: ChatViewModel.UpdateReason?

    init(runtime: ChatRuntime, conversation: ChatConversation) {
        self.runtime = runtime; self.conversation = conversation
    }
    func start(in controller: ChatViewController) {
        self.controller = controller
        controller.navigationItem.titleView = nil
        let selfConversation = conversation
        ConversationDetailsNavigation.install(on: controller, runtime: runtime, conversation: { [weak self] in self?.conversation ?? selfConversation }) { [weak self] message in
            guard let self else { throw ChatStoreError.unavailable }
            try await locate(message)
        }
        observer = runtime.observe { [weak self] in self?.refresh() }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self, !stopped else { break }
                viewportChanged()
                if let deadline = nextDeadline, Date() >= deadline { nextDeadline = nil; refresh() }
            }
        }
        refresh()
        loadHistory()
    }
    func didAppear() { runtime.enteredConversation(conversation.id) }
    func locate(_ message: ChatMessage) async throws {
        guard let engine = runtime.engine, let controller,
              try await engine.store.visibleMessage(message.id, conversation: conversation.id) != nil,
              runtime.engine === engine else { throw ChatStoreError.unavailable }
        contextAnchor = message.id
        controller.conversationView.requestMessageFocus(identity(message.id))
        pendingReason = .olderHistoryLoaded
        refresh()
        await reloadTask?.value
        controller.viewModel.historyState = .exhausted
        controller.viewModel.publish(reason: .historyStatus)
        controller.latestMessagesButton.isHidden = false
        controller.setNeedsQuickLayout()
    }
    func leaveSearchContext() {
        guard contextAnchor != nil else { return }
        contextAnchor = nil
        focusLatestAfterLoad = true
        controller?.viewModel.historyState = page?.hasMore == false ? .exhausted : .idle
        pendingReason = .historyLoaded
        refresh()
    }
    func identity(_ id: String) -> Int {
        let key = id.lowercased()
        if let value = identities[key] { return value }
        let value = identities.count + 1
        identities[key] = value; sourceIDs[value] = key
        return value
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        if let observer { runtime.remove(observer) }; observer = nil
        if let directory = controller?.attachmentStore.directoryURL {
            runtime.originalDraftStore?.legacyLoaders[directory] = nil
        }
        reloadTask?.cancel(); historyTask?.cancel(); clockTask?.cancel(); readTask?.cancel()
        mediaTasks.values.forEach { $0.cancel() }; mediaTasks.removeAll()
        operations.values.forEach { $0.cancel() }; operations.removeAll()
        mediaStores.values.forEach { $0.removeAll() }; mediaStores.removeAll()
        contents.removeAll(); messages.removeAll(); pending.removeAll(); uploads.removeAll()
    }
    isolated deinit {
        if let observer { runtime.remove(observer) }
        reloadTask?.cancel(); historyTask?.cancel(); clockTask?.cancel(); readTask?.cancel()
        for task in mediaTasks.values { task.cancel() }
        for task in operations.values { task.cancel() }
    }
    func refresh() {
        guard !stopped, let controller, controller.isViewLoaded else { return }
        guard let engine = runtime.engine else {
            stop()
            controller.audioController.stopAll()
            controller.audioTranscription.cancelAll()
            controller.composerView.restoreDraft(segments: [], documents: [:])
            controller.viewModel.messages = []
            controller.viewModel.publish(reason: .messageDeleted)
            controller.attachmentStore.removeAll()
            controller.composerView.isUserInteractionEnabled = false
            return
        }
        controller.title = runtime.title(conversation)
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded: [ChatMessage]
                if let contextAnchor { loaded = try await engine.store.messageContext(contextAnchor, conversation: conversation.id) }
                else { loaded = try await engine.store.messages(conversation.id, limit: historyLimit) }
                let pending = try await engine.store.pending().filter { $0.outgoing.conversationID == conversation.id }
                let uploads = try await engine.store.transfers(as: ChatUploadBatch.self).filter { $0.conversation == conversation.id }
                let order = try await engine.store.orderedMessageIDs(conversation: conversation.id)
                let availability = try await engine.store.reeditAvailability(conversation: conversation.id)
                try Task.checkCancellation()
                guard !stopped, runtime.engine === engine else { return }
                let previous = Set(messages.map(\.id))
                if hasRendered, !loadingHistory, let last = loaded.last, let old = messages.last,
                   last.sequence > old.sequence {
                    let list = controller.conversationView.collectionView
                    if list.contentSize.height + list.adjustedContentInset.bottom - list.contentOffset.y - list.bounds.height > 100 {
                        controller.latestMessagesButton.isHidden = false
                        controller.setNeedsQuickLayout()
                    }
                }
                messages = loaded; self.pending = pending; self.uploads = uploads
                let current = runtime.conversations.first { $0.id == conversation.id } ?? conversation
                if current.boundaryRevision != conversation.boundaryRevision { page = nil; visible.removeAll() }
                conversation = current
                reeditable = Set(availability.map(\.messageID))
                let now = Date()
                nextDeadline = (availability.map(\.expiresAt) + loaded.filter { $0.senderID == runtime.userID && !$0.revoked }
                    .map { Date(timeIntervalSince1970: Double($0.createdAt + 120001) / 1000) }).filter { $0 > now }.min()
                var values = loaded.map { presentation($0) }
                let authoritative = Set(loaded.map(\.id))
                let queued = Dictionary(uniqueKeysWithValues: pending.map { ($0.outgoing.id.uuidString.lowercased(), $0) })
                let transferring = Dictionary(uniqueKeysWithValues: uploads.map { ($0.messageID.uuidString.lowercased(), $0) })
                for key in order where !authoritative.contains(key) {
                    if let item = queued[key] { values.append(presentation(item)) }
                    else if let item = transferring[key] { values.append(presentation(item)) }
                }
                let allowed = runtime.canSend(conversation)
                controller.composerView.isUserInteractionEnabled = allowed && !controller.isRestoringDraft && !controller.isSubmittingComposition
                controller.viewModel.sessionNotice = !allowed ? Localization.text(conversation.closed ? "chat.live.closed" : "chat.live.friendRequired")
                    : runtime.online ? nil : Localization.text("chat.live.offline")
                controller.viewModel.messages = values
                let reason: ChatViewModel.UpdateReason = pendingReason ?? (!hasRendered ? .historyLoaded
                    : !Set(loaded.map(\.id)).subtracting(previous).isEmpty && !loadingHistory ? .receivedMessage : .messageStatus)
                pendingReason = nil
                hasRendered = true
                if focusLatestAfterLoad, contextAnchor == nil {
                    focusLatestAfterLoad = false
                    controller.conversationView.requestLatestMessageFocus()
                    controller.latestMessagesButton.isHidden = true
                    controller.setNeedsQuickLayout()
                }
                controller.viewModel.publish(reason: reason)
                scheduleMedia()
                viewportChanged()
            } catch is CancellationError {} catch { showFailure() }
        }
    }
    func presentation(_ message: ChatMessage) -> Message {
        let id = identity(message.id)
        let outgoing = message.senderID == runtime.userID
        var result = Message(id: id, direction: outgoing ? .outgoing : .incoming,
            content: content(message), sentAt: Date(timeIntervalSince1970: Double(message.createdAt) / 1000))
        if message.kind == "system" {
            result.systemNotice = ChatSystemNotice.text(message, userID: runtime.userID)
            return result
        }
        if outgoing && !message.revoked {
            let receipt = message.receipt
            let read = receipt.expected > 0 && receipt.read == receipt.expected
            let delivered = receipt.expected > 0 && receipt.delivered == receipt.expected
            result.deliveryState = read ? .read : delivered ? .delivered : nil
            result.statusText = Localization.text("chat.live." + (read ? "read" : delivered ? "delivered" : "sent"))
            result.canRevoke = Date().timeIntervalSince1970 * 1000 <= Double(message.createdAt + 120000)
        }
        if conversation.kind == "group" && !outgoing {
            result.senderName = runtime.contacts.first { $0.peer.id == message.senderID }?.peer.nickname
                ?? conversation.members.first { $0.id == message.senderID }?.profile.nickname
                ?? Localization.text("chat.live.groupMember")
        }
        if mediaFailures.contains(message.id) { result.canRetryMedia = true; result.statusText = Localization.text("chat.live.failed") }
        if message.revoked {
            result.revokedNotice = Localization.text(outgoing ? "chat.live.revokedSelf" : "chat.live.revokedOther")
            result.canReedit = outgoing && runtime.canSend(conversation) && reeditable.contains(message.id)
            evict(message.id)
        }
        return result
    }
    func content(_ message: ChatMessage) -> MessageContent {
        if message.revoked || message.kind == "system" { return .userText("") }
        if let cached = contents[message.id] { return cached }
        if message.kind == "link", let url = URL(string: message.linkURL ?? message.text) {
            return .attachment(.link(.init(id: UUID(uuidString: message.id) ?? UUID(), url: url)))
        }
        if message.kind == "text" {
            let runs = message.textRuns ?? []
            return runs.isEmpty ? .userText(message.text) : .richText(.init(runs: runs.map { .init($0.text, style: .init(rawValue: Int($0.style))) }))
        }
        let name = message.assets.flatMap(\.resources).filter { $0.role == "original" }.map(\.filename).joined(separator: "\n")
        return .userText(name.isEmpty ? Localization.text("chat.live.media_group") : name)
    }
    func presentation(_ pending: ChatPendingMessage) -> Message {
        let outgoing = pending.outgoing, key = outgoing.id.uuidString.lowercased()
        let content: MessageContent = contents[key] ?? (outgoing.kind == "link"
            ? .attachment(.link(.init(id: outgoing.id, url: URL(string: outgoing.linkURL ?? outgoing.text)!)))
            : (outgoing.textRuns ?? []).isEmpty ? .userText(outgoing.text.isEmpty ? Localization.text("chat.live.media_group") : outgoing.text)
            : .richText(.init(runs: (outgoing.textRuns ?? []).map { .init($0.text, style: .init(rawValue: Int($0.style))) })))
        return Message(id: identity(key), direction: .outgoing, content: content, sentAt: pending.createdAt,
            deliveryState: pending.state == "failed" ? .failed : .sending, statusText: Localization.text("chat.live." + pending.state), canCancel: true)
    }
    func presentation(_ batch: ChatUploadBatch) -> Message {
        let key = batch.messageID.uuidString.lowercased()
        let total = batch.items.flatMap(\.resources).reduce(Int64(0)) { $0 + $1.input.bytes }
        let state = Localization.text("chat.live." + (batch.cancelRequested ? "cancelling" : batch.state))
        let status = state + (batch.state == "uploading" && total > 0 ? " · \(min(100, batch.completedBytes * 100 / total))%" : "")
        return Message(id: identity(key), direction: .outgoing,
            content: contents[key] ?? .userText(batch.items.compactMap { $0.resources.first?.input.filename }.joined(separator: "\n")),
            sentAt: batch.createdAt, deliveryState: batch.state == "failed" ? .failed : .sending, statusText: status, canCancel: true)
    }
    func loadHistory() {
        guard contextAnchor == nil, !stopped, !loadingHistory, page?.hasMore != false, let engine = runtime.engine else { return }
        let initialPage = page == nil
        loadingHistory = true
        controller?.viewModel.historyState = .loading
        controller?.viewModel.publish(reason: .historyStatus)
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer { loadingHistory = false }
            do {
                let value = try await engine.history(conversation.id, before: page?.before ?? 0, upper: page?.upper ?? 0, boundary: page?.boundary ?? 0)
                try Task.checkCancellation()
                guard !stopped, runtime.engine === engine else { return }
                page = value; historyLimit += value.messages.count
                controller?.viewModel.historyState = value.hasMore ? .idle : .exhausted
                pendingReason = initialPage ? .historyLoaded : .olderHistoryLoaded
                refresh()
            } catch is CancellationError {} catch {
                controller?.viewModel.historyState = .failed
                controller?.viewModel.publish(reason: .historyStatus)
            }
        }
    }
    func viewportChanged() {
        guard !stopped, readTask == nil, let controller, controller.viewIfLoaded?.window != nil,
              UIApplication.shared.applicationState == .active else { return }
        let list = controller.conversationView.collectionView
        guard !list.isDragging, !list.isDecelerating else { return }
        scheduleMedia()
        if contextAnchor == nil,
           list.contentSize.height + list.adjustedContentInset.bottom - list.contentOffset.y - list.bounds.height < 80,
           !controller.latestMessagesButton.isHidden {
            controller.latestMessagesButton.isHidden = true
            controller.setNeedsQuickLayout()
        }
        for id in controller.conversationView.visibleMessageIDs {
            guard let key = sourceIDs[id], let value = messages.first(where: { $0.id == key }) else { continue }
            visible.insert(value.sequence)
        }
        var through = conversation.readState.read
        let intervals = conversation.members.first { $0.id == runtime.userID }?.intervals ?? []
        while through < conversation.latest {
            let next = through + 1
            if intervals.contains(where: { next >= $0.joined && ($0.left == 0 || next < $0.left) }) {
                guard visible.contains(next) else { break }
                through = next
            } else if let joined = intervals.map(\.joined).filter({ $0 > next }).min(), visible.contains(joined) {
                through = joined
            } else { break }
        }
        guard through > conversation.readState.read, let engine = runtime.engine else { return }
        let value = through
        readTask = Task { [weak self] in
            guard let self else { return }
            defer { readTask = nil }
            try? await engine.markRead(conversation, visibleThrough: value)
        }
    }
    func showFailure() {
        guard !stopped, let controller, controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: Localization.text("chat.live.failed"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("imessage.action.ok"), style: .default))
        controller.present(alert, animated: true)
    }
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        operations[id] = Task { [weak self] in
            defer { self?.operations[id] = nil }
            do { try await work() } catch is CancellationError {} catch { self?.showFailure() }
        }
    }
}
