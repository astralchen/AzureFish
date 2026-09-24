import Foundation
import Testing
import QuickLayoutKit
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatMessageStatusTests {
    @Test func deliveryReadAndTypingAreSeparateEvents() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("hello"))
        #expect(message(model, 0)?.deliveryState == .sending)
        #expect(!model.state.isTyping && model.state.isProcessingMessages)
        #expect(await eventually { sender.calls.count == 1 })
        sender.resolve(0, success: true)
        #expect(await eventually { delay.calls.count == 1 })
        #expect(delay.calls == [.milliseconds(300)])
        #expect(message(model, 0)?.deliveryState == .delivered)
        #expect(!model.state.isTyping)
        delay.resume()
        #expect(await eventually { delay.calls.count == 2 })
        #expect(message(model, 0)?.deliveryState == .read)
        #expect(model.state.isTyping)
        #expect(message(model, 1) == nil)
        delay.resume()
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 1)?.direction == .incoming)
        #expect(!model.state.isTyping)
    }

    @Test func failedMessagesRemainVisibleAndRetryKeepsIdentityAndRejectsDoubleTap() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("first"))
        #expect(model.send("second"))
        #expect(await eventually { sender.calls.count == 2 })
        sender.resolve(0, success: false)
        sender.resolve(1, success: false)
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 0)?.deliveryText == "imessage.status.failed")
        #expect(message(model, 1)?.deliveryText == "imessage.status.failed")
        #expect(delay.calls.isEmpty)
        let original = try #require(sender.calls.first)
        #expect(model.retryMessage(id: 0))
        #expect(!model.retryMessage(id: 0))
        #expect(!model.retryMessage(id: 999))
        #expect(await eventually { sender.calls.count == 3 })
        #expect(sender.calls[2].id == original.id)
        #expect(sender.calls[2].content == original.content)
        #expect(sender.calls[2].sentAt == original.sentAt)
        #expect(message(model, 0)?.deliveryState == .sending)
        sender.resolve(2, success: true)
        #expect(await eventually { delay.calls.count == 1 })
        delay.resume()
        #expect(await eventually { delay.calls.count == 2 })
        delay.resume()
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 0)?.deliveryState == .read)
        #expect(message(model, 1)?.deliveryState == .failed)
        #expect(message(model, 1)?.deliveryText == "imessage.status.failed")
        #expect(message(model, 2)?.direction == .incoming)
        #expect(!model.retryMessage(id: 2))
        #expect(message(model, 3) == nil)
    }

    @Test func receiptsAreMonotonicAndNeverReadFailedOrInFlightMessages() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.sendContents([.userText("one"), .userText("two"), .userText("three")]))
        #expect(await eventually { sender.calls.count == 3 })
        sender.resolve(1, success: false)
        sender.resolve(2, success: true)
        #expect(await eventually { message(model, 2)?.deliveryState == .delivered })
        #expect(delay.calls.isEmpty) // 第一条尚未送达，不能越过队列开始回复。
        model.receiveReadReceipt(through: 999)
        #expect(message(model, 2)?.deliveryState == .delivered)
        model.receiveReadReceipt(through: 2)
        #expect(message(model, 0)?.deliveryState == .sending)
        #expect(message(model, 1)?.deliveryState == .failed)
        #expect(message(model, 2)?.deliveryState == .read)
        model.receiveReadReceipt(through: 1)
        #expect(message(model, 2)?.deliveryState == .read)
        model.cancelPendingReply()
        sender.resolve(0, success: true)
        #expect(await eventually { sender.completed == 3 })
        #expect(message(model, 0)?.deliveryState == .failed)
        #expect(!model.state.isProcessingMessages)
    }

    @Test func repliesDoNotImplyReadWhenReceiptsAreDisabled() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay, receipts: false)
        defer { model.cancelPendingReply() }
        #expect(model.send("hello"))
        #expect(await eventually { sender.calls.count == 1 })
        sender.resolve(0, success: true)
        #expect(await eventually { delay.calls.count == 1 })
        delay.resume()
        #expect(await eventually { delay.calls.count == 2 })
        #expect(model.state.isTyping)
        #expect(message(model, 0)?.deliveryState == .delivered)
        delay.resume()
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 1)?.direction == .incoming)
        #expect(message(model, 0)?.deliveryState == .delivered)
    }

    @Test func failedDelayReleasesTypingAndAllowsFollowingMessages() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("first"))
        #expect(await eventually { sender.calls.count == 1 })
        sender.resolve(0, success: true)
        #expect(await eventually { delay.calls.count == 1 })
        delay.resume()
        #expect(await eventually { delay.calls.count == 2 })
        #expect(model.state.isTyping)
        delay.resume(fails: true)
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(!model.state.isTyping)
        #expect(message(model, 0)?.deliveryState == .read)
        #expect(model.send("next"))
        #expect(await eventually { sender.calls.count == 2 })
        sender.resolve(1, success: false)
        #expect(await eventually { !model.state.isProcessingMessages })
    }

    @Test func cancelAndRetryIgnoreLateSendCompletionFromEarlierAttempt() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("first"))
        #expect(await eventually { sender.calls.count == 1 })
        model.cancelPendingReply()
        #expect(model.retryMessage(id: 0))
        #expect(await eventually { sender.calls.count == 2 })
        sender.resolve(0, success: true)
        #expect(await eventually { sender.completed == 1 })
        #expect(message(model, 0)?.deliveryState == .sending)
        sender.resolve(1, success: false)
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 0)?.deliveryState == .failed)
        #expect(delay.calls.isEmpty)
    }

    @Test func statusViewSupportsRetryReuseRTLAndLargeText() {
        guard #available(iOS 26.0, *) else { return }
        let view = DeliveryStatusView()
        var ids: [Int] = []
        view.retryRequested = { ids.append($0) }
        let failed = MessagePresentation(id: 7, direction: .outgoing, text: "x",
                                                     deliveryText: "尚未送达", deliveryState: .failed)
        view.configure(failed)
        let size = view.sizeThatFits(.init(width: 180, height: 100))
        #expect(size.width >= 44 && size.height >= 44)
        view.frame = .init(origin: .zero, size: size)
        view.layoutIfNeeded()
        #expect(view.label.frame.minX == 26)
        #expect(view.progress.superview == nil)
        view.semanticContentAttribute = .forceRightToLeft
        view.layoutIfNeeded()
        #expect(view.label.frame.minX == 0)
        #expect(view.accessibilityTraits.contains(.button))
        view.sendActions(for: .touchUpInside)
        #expect(ids == [7])
        #expect(view.accessibilityActivate())
        #expect(ids == [7, 7])
        let sending = MessagePresentation(id: 8, direction: .outgoing, text: "x",
                                                      deliveryText: "发送中…", deliveryState: .sending)
        view.configure(sending)
        view.frame.size = view.sizeThatFits(.init(width: 180, height: 100))
        view.layoutIfNeeded()
        #expect(view.progress.isDescendant(of: view))
        #expect(view.progress.frame.width == 20 && view.progress.frame.height == 20)
        #expect(abs(view.progress.frame.minX - view.label.frame.maxX - 6) < 1)
        view.sendActions(for: .touchUpInside)
        #expect(ids == [7, 7] && view.progress.isAnimating)
        #expect(!view.accessibilityActivate())
        view.label.font = .systemFont(ofSize: 34)
        #expect(view.sizeThatFits(.init(width: 100, height: 300)).height > 44)
        view.configure(nil)
        view.layoutIfNeeded()
        #expect(view.progress.superview == nil)
        view.sendActions(for: .touchUpInside)
        #expect(ids == [7, 7] && !view.progress.isAnimating)
        #expect(view.accessibilityHint == nil)
        #expect(sending.refreshIdentity != MessagePresentation(id: 8, direction: .outgoing,
            text: "x", deliveryText: "发送中…", deliveryState: .failed).refreshIdentity)
    }

    @Test func rapidStatusRendersRefreshVisibleCellsAndRemovePreviousReceipt() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        let conversation = ConversationView(frame: window.bounds)
        host.view = conversation
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        func state(oldText: String?, status: MessageDeliveryState?, text: String?, incoming: Bool = false) -> ChatViewModel.State {
            var rows = [TimelineItem(id: .message(1), content: .message(.init(
                id: 1, direction: .outgoing, text: "old", deliveryText: oldText, deliveryState: .read)))]
            if let status {
                rows.append(.init(id: .message(3), content: .message(.init(
                    id: 3, direction: .outgoing, text: "new", deliveryText: text, deliveryState: status))))
            }
            if incoming { rows.append(.init(id: .message(4), content: .message(.init(
                id: 4, direction: .incoming, text: "reply", deliveryText: nil)))) }
            return .init(timeline: rows, isTyping: false)
        }
        func labels() -> [String] {
            conversation.collectionView.layoutIfNeeded()
            return conversation.collectionView.visibleCells.compactMap { ($0 as? TextBubbleCell)?.deliveryLabel.text }.sorted()
        }
        conversation.render(state(oldText: "old read", status: nil, text: nil), reason: .initial)
        #expect(await eventually { labels() == ["old read"] })
        conversation.render(state(oldText: nil, status: .sending, text: "sending"), reason: .sentMessage)
        conversation.render(state(oldText: nil, status: .failed, text: "failed"), reason: .messageStatus)
        conversation.render(state(oldText: nil, status: .sending, text: "sending"), reason: .messageStatus)
        conversation.render(state(oldText: nil, status: .delivered, text: "delivered"), reason: .messageStatus)
        conversation.render(state(oldText: nil, status: .read, text: "read"), reason: .messageStatus)
        conversation.render(state(oldText: nil, status: .read, text: "read", incoming: true), reason: .receivedMessage)
        conversation.render(state(oldText: nil, status: .read, text: "read", incoming: true), reason: .messageStatus)
        #expect(await eventually { labels() == ["read"] })
        #expect(conversation.collectionView.visibleCells.compactMap { $0 as? TextBubbleCell }.allSatisfy {
            !$0.deliveryStatusView.progress.isAnimating && !$0.deliveryStatusView.isUserInteractionEnabled
        })
    }

    @Test func deleteSendingMessageIgnoresLateCompletionAndKeepsNextSend() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("delete"))
        #expect(model.send("keep"))
        #expect(await eventually { sender.calls.count == 2 })
        #expect(model.deleteMessage(id: 0))
        #expect(!model.deleteMessage(id: 0))
        sender.resolve(0, success: true)
        sender.resolve(1, success: false)
        #expect(await eventually { sender.completed == 2 && !model.state.isProcessingMessages })
        #expect(message(model, 0) == nil)
        #expect(message(model, 1)?.deliveryState == .failed)
        #expect(model.retryMessage(id: 1))
        #expect(await eventually { sender.calls.count == 3 })
        sender.resolve(2, success: false)
        #expect(await eventually { sender.completed == 3 })
        #expect(model.deleteMessage(id: 1))
        #expect(model.state.timeline.isEmpty)
    }

    @Test func deletingActiveReplyRejectsOldWorkerAndContinuesQueue() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sender = StatusSender(), delay = StatusDelay()
        let model = makeModel(sender, delay)
        defer { model.cancelPendingReply() }
        #expect(model.send("delete"))
        #expect(model.send("keep"))
        #expect(await eventually { sender.calls.count == 2 })
        sender.resolve(0, success: true)
        sender.resolve(1, success: true)
        #expect(await eventually { delay.calls.count == 1 })
        delay.resume()
        #expect(await eventually { model.state.isTyping && delay.calls.count == 2 })
        #expect(model.deleteMessage(id: 0))
        #expect(!model.state.isTyping)
        #expect(await eventually { delay.calls.count == 3 })
        delay.resume() // 删除前尚未完成的旧回复。
        delay.resume() // 下一条消息的阅读延迟。
        #expect(await eventually { delay.calls.count == 4 })
        delay.resume()
        #expect(await eventually { !model.state.isProcessingMessages })
        #expect(message(model, 0) == nil)
        #expect(model.messages.filter { $0.direction == .incoming }.count == 1)
        #expect(message(model, 1)?.deliveryState == .read)
    }

    @available(iOS 26.0, *)
    private func makeModel(_ sender: StatusSender, _ delay: StatusDelay, receipts: Bool = true) -> ChatViewModel {
        ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init,
                             messageSender: sender, readReceiptsEnabled: receipts, sleeper: { try await delay.sleep($0) })
    }
    @available(iOS 26.0, *)
    private func message(_ model: ChatViewModel, _ id: Int) -> MessagePresentation? {
        model.state.timeline.compactMap { if case .message(let message) = $0.content { message } else { nil } }
            .first { $0.id == id }
    }
    @available(iOS 26.0, *)
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

@available(iOS 26.0, *)
@MainActor
private final class StatusSender: MessageSending {
    var calls: [Message] = []
    var completed = 0
    private var waits: [Int: CheckedContinuation<Void, Error>] = [:]
    func send(_ message: Message) async throws {
        let index = calls.count
        calls.append(message)
        defer { completed += 1 }
        try await withCheckedThrowingContinuation { waits[index] = $0 }
    }
    func resolve(_ index: Int, success: Bool) {
        if success { waits.removeValue(forKey: index)?.resume() }
        else { waits.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileWriteUnknown)) }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class StatusDelay {
    var calls: [Duration] = []
    private var waits: [CheckedContinuation<Void, Error>] = []
    func sleep(_ duration: Duration) async throws {
        calls.append(duration)
        try await withCheckedThrowingContinuation { waits.append($0) }
    }
    func resume(fails: Bool = false) {
        let wait = waits.removeFirst()
        if fails { wait.resume(throwing: CocoaError(.userCancelled)) } else { wait.resume() }
    }
}
