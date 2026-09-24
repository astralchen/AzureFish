import AppLocalization
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatTextInsertionTests {
    @Test(arguments: ["short", "multiline", "wrapped"], [false, true])
    func replyTextRendersImmediatelyWithoutMovingHistory(kind: String, readingHistory: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let text: String = switch kind {
        case "short": "收到，这是回复。"
        case "multiline": "第一行：回复应完整显示\n第二行：不等待下次刷新\n第三行：气泡底部也完整可见\n第四行：正在输入结束后显示回复"
        default: String(repeating: "这是对方回复的长文本，自动换行后也应立即完整显示。", count: 5)
        }
        let model = ChatViewModel(localizer: Localizer { key, _ in
            key == "imessage.reply.1" ? text : key
        }, clock: Date.init, sleeper: { try await Task.sleep(for: $0) })
        let controller = ChatViewController(viewModel: model)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = try makeVisibleTestWindow(rootViewController: UINavigationController(rootViewController: controller))
        defer { model.cancelPendingReply(); window.isHidden = true; previous?.makeKey() }
        model.insertInitialHistory((0..<20).map { index in
            MessageHistoryEntry(direction: .incoming, content: .userText("历史消息 \(index)"))
        })
        controller.composerView.textView.becomeFirstResponder()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(model.send("请回复这条消息"))
        for _ in 0..<150 {
            if model.isTyping { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.isTyping)
        try await Task.sleep(nanoseconds: 100_000_000)
        let collection = controller.conversationView.collectionView
        if readingHistory { collection.setContentOffset(.zero, animated: false) }
        collection.layoutIfNeeded()
        let previousOffset = collection.contentOffset
        let originalRender = model.render
        var receivedReply = false
        model.render = { state, reason in
            originalRender?(state, reason)
            if reason == .receivedMessage { receivedReply = true }
        }
        for _ in 0..<200 {
            if receivedReply { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(receivedReply)
        for index in 0..<8 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if index == 0 || index == 7 {
                let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try capture.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("text-reply-\(kind)-\(readingHistory)-\(index).png"))
            }
            if readingHistory {
                #expect(abs(collection.contentOffset.y - previousOffset.y) < 1)
            } else {
                let cell = try #require(collection.visibleCells.compactMap { $0 as? TextBubbleCell }
                    .first { $0.bubbleView.messageTextView.text == text })
                let body = cell.bubbleView.messageTextView
                expectSettledTextGeometry(cell.contentView)
                let presentedBody = try #require(body.layer.presentation())
                let presentedCollection = try #require(collection.layer.presentation())
                let frame = presentedBody.convert(presentedBody.bounds, to: presentedCollection)
                #expect(frame.minY >= presentedCollection.bounds.minY - 1)
                #expect(frame.maxY <= presentedCollection.bounds.maxY + 1)
                #expect(body.contentSize.height <= body.bounds.height + 1)
            }
        }
    }

    @Test(arguments: ["short", "multiline", "wrapped", "rich"])
    func sendingTextRendersDuringInsertion(kind: String) async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        // 保持发送中，避免送达刷新意外修正首次布局而掩盖缺陷。
        let model = ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init,
                                  messageSender: PendingTextSender(), sleeper: { try await Task.sleep(for: $0) })
        let controller = ChatViewController(viewModel: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { model.cancelPendingReply(); window.isHidden = true; previous?.makeKey() }
        model.insertInitialHistory((0..<20).map { index in
            MessageHistoryEntry(direction: .incoming, content: .userText("历史消息 \(index)"))
        })
        try await Task.sleep(nanoseconds: 300_000_000)
        let composer = controller.composerView
        composer.textView.becomeFirstResponder()
        try await Task.sleep(nanoseconds: 400_000_000)
        let text: String = switch kind {
        case "short": "短消息"
        case "multiline": "第一行：发送后应该立即完整显示\n第二行：测试多行文本和气泡布局\n第三行：最后一行也不能被裁剪\n第四行：长消息应在发送时出现\n第五行：检查消息底部完整可见"
        default: String(repeating: "长文本发送后应该立即完整显示，自动换行不能导致消息暂时消失。", count: 5)
        }
        if kind == "rich" {
            composer.textView.attributedText = MessageText(runs: [.init(text, style: [.bold, .underline])])
                .attributedString(font: .preferredFont(forTextStyle: .body), color: .label)
        } else {
            composer.textView.text = text
        }
        composer.textViewDidChange(composer.textView)
        try await Task.sleep(nanoseconds: 300_000_000)
        composer.sendButtonDidTap()
        let collection = controller.conversationView.collectionView
        // 单行草稿不会触发输入栏收起；允许列表先把末尾新 Cell 滚入视口，
        // 从它的第一个呈现帧开始检查，不能等送达刷新或文本动画结束。
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if collection.visibleCells.compactMap({ $0 as? TextBubbleCell }).contains(where: {
                $0.bubbleView.messageTextView.text == text && $0.bubbleView.messageTextView.layer.presentation() != nil
            }) { break }
        }
        for index in 0..<8 {
            if index > 0 { try await Task.sleep(nanoseconds: 25_000_000) }
            // 必须找到刚发出的气泡，不能让未显示消息的情况空循环通过。
            let cell = try #require(collection.visibleCells.compactMap { $0 as? TextBubbleCell }
                .first { $0.bubbleView.messageTextView.text == text })
            let body = cell.bubbleView.messageTextView
            _ = try #require(body.layer.presentation())
            expectSettledTextGeometry(cell.contentView)
            #expect(abs(body.contentOffset.y) < 0.5)
            #expect(body.contentSize.height <= body.bounds.height + 1)
            let bodyFrame = body.convert(body.bounds, to: collection)
            #expect(bodyFrame.maxY <= collection.bounds.maxY - collection.adjustedContentInset.bottom + 1)
            if let presentedBody = body.layer.presentation(), let presentedCollection = collection.layer.presentation() {
                let presentedFrame = presentedBody.convert(presentedBody.bounds, to: presentedCollection)
                #expect(presentedFrame.maxY <= presentedCollection.bounds.maxY + 1)
            }
            #expect(model.messages.last?.deliveryState == .sending)
            if index == 0 || index == 7 {
                let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try capture.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("text-insertion-\(kind)-\(index).png"))
            }
        }
    }

    /// 正文和 UIKit 内部绘制视图都必须立即采用最终尺寸；只检查正文 frame 会漏掉内部裁剪。
    private func expectSettledTextGeometry(_ view: UIView) {
        if let presented = view.layer.presentation() {
            #expect(abs(presented.bounds.width - view.bounds.width) < 0.5)
            #expect(abs(presented.bounds.height - view.bounds.height) < 0.5)
        }
        view.subviews.forEach(expectSettledTextGeometry)
        if let mask = view.mask { expectSettledTextGeometry(mask) }
    }
}

@MainActor
private final class PendingTextSender: MessageSending {
    func send(_ message: Message) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}
