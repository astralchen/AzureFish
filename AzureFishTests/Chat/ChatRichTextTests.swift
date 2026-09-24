import Testing
import UIKit
import AppLocalization
import QuickLayoutKitUIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatRichTextTests {
    @Test func semanticRunsNormalizeWithoutLosingUnicodeOrWhitespace() {
        let text = MessageText(runs: [.init("  中文👨‍👩‍👧‍👦", style: .bold), .init("\n", style: .bold),
                                      .init("مرحبا", style: [.italic, .underline]), .init("")])
        #expect(text.runs.count == 2)
        let attributed = text.attributedString(font: .systemFont(ofSize: 17), color: .white)
        #expect(MessageText(attributedString: attributed) == text)
        #expect(text.text == "  中文👨‍👩‍👧‍👦\nمرحبا")
    }

    @Test func formattingPreservesOtherStylesAndSuspension() throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(frame: .zero)
        composer.textView.text = "中文👨‍👩‍👧‍👦 hello"
        let range = (composer.textView.text as NSString).range(of: "中文👨‍👩‍👧‍👦")
        composer.textView.selectedRange = range
        composer.toggleFormatting(.bold, range: range)
        composer.toggleFormatting(.underline, range: range)
        var text = MessageText(attributedString: composer.textView.attributedText)
        #expect(text.runs.first?.style == [.bold, .underline])
        #expect(text.runs.last?.style == [])
        #expect(composer.textView.selectedRange == range)
        composer.toggleFormatting(.bold, range: range)
        text = MessageText(attributedString: composer.textView.attributedText)
        #expect(text.runs.first?.style == .underline)
        composer.isShowingRecordingUnavailableHint = true
        composer.toggleFormatting(.italic, range: range)
        #expect(MessageText(attributedString: composer.textView.attributedText) == text)
    }

    @Test func mixedSelectionsAndAttachmentsKeepTheirIdentity() throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(frame: .zero)
        let draft = DocumentDraft(attachment: .link(.init(url: URL(string: "https://apple.com")!)))
        composer.insertContents([.text("前👋"), .attachment(draft), .text("后\n")])
        let range = NSRange(location: 0, length: composer.textView.textStorage.length)
        composer.toggleFormatting(.strikethrough, range: range)
        let segments = composer.draftSegments
        #expect(segments == [.richText(.init(runs: [.init("前👋", style: .strikethrough)])),
                             .attachment(draft.id), .richText(.init(runs: [.init("后\n", style: .strikethrough)]))])
        #expect(composer.orderedDocumentIDs == [draft.id])
        #expect(composer.plainDraftText == "前👋后\n")
        composer.toggleFormatting(.strikethrough, range: range)
        #expect(composer.draftSegments == [.text("前👋"), .attachment(draft.id), .text("后\n")])
    }

    @Test func editorKeepsTypingStyleAndResetsAfterAcceptedSend() throws {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(frame: .zero)
        composer.textView.text = "Hello"
        composer.toggleFormatting(.italic, range: NSRange(location: 0, length: 5))
        composer.textView.selectedRange = NSRange(location: 5, length: 0)
        composer.textView.insertText(" 👋")
        composer.textViewDidChange(composer.textView)
        let text = MessageText(attributedString: composer.textView.attributedText)
        #expect(text.runs == [.init("Hello 👋", style: .italic)])
        var action: ComposerAction?
        composer.actionRequested = { action = $0; return false }
        composer.sendButtonDidTap()
        #expect(action == .sendDocuments([.richText(text)]))
        #expect(MessageText(attributedString: composer.textView.attributedText) == text)
        composer.actionRequested = { action = $0; return true }
        composer.sendButtonDidTap()
        #expect(composer.plainDraftText.isEmpty)
        #expect(MessageText.Style(attributes: composer.textView.typingAttributes).isEmpty)
    }

    @Test func controllerSendsFormattingAndLocalizationRetainsIt() throws {
        guard #available(iOS 26.0, *) else { return }
        let controller = ChatViewController()
        controller.loadViewIfNeeded()
        defer { controller.viewModel.cancelPendingReply() }
        let composer = controller.composerView
        composer.textView.text = "中文 Bold 👋\nمرحبا"
        composer.toggleFormatting(.bold, range: (composer.textView.text as NSString).range(of: "Bold"))
        let expected = MessageText(attributedString: composer.textView.attributedText)
        composer.sendButtonDidTap()
        #expect(controller.viewModel.messages.last?.content == .richText(expected))
        controller.viewModel.publish(reason: .localization)
        let messages = controller.viewModel.state.timeline.compactMap { item -> MessagePresentation? in
            if case .message(let value) = item.content { return value }; return nil
        }
        #expect(messages.last?.content == .richText(expected))
        #expect(composer.plainDraftText.isEmpty)
    }

    @Test(arguments: [false, true])
    func formattedConversationAppearanceAndUndo(rtl: Bool) async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = ChatViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            controller.viewModel.cancelPendingReply()
            window.isHidden = true
            previousWindow?.makeKey()
        }
        let composer = controller.composerView
        controller.view.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        composer.applyLayoutDirection(rtl ? .rightToLeft : .leftToRight)
        controller.conversationView.applyLayoutDirection(rtl ? .rightToLeft : .leftToRight)
        let value = MessageText(runs: [
            .init("明天一起去 Apple Park 👋\n"),
            .init("Bold 粗体", style: .bold), .init(" · "), .init("Italic 斜体\n", style: .italic),
            .init("Underline 下划线", style: .underline), .init("\n"),
            .init("原计划 10:00", style: .strikethrough), .init(" → 11:00\n"),
            .init("مرحبا بالعالم", style: [.bold, .underline]),
        ])
        composer.textView.attributedText = value.attributedString(font: .preferredFont(forTextStyle: .body), color: .label)
        composer.textViewDidChange(composer.textView)
        #expect(composer.textView.becomeFirstResponder())
        let undo = try #require(composer.textView.undoManager)
        undo.removeAllActions()
        let range = (value.text as NSString).range(of: "Apple Park")
        undo.beginUndoGrouping()
        composer.toggleFormatting(.bold, range: range)
        undo.endUndoGrouping()
        #expect(MessageText(attributedString: composer.textView.attributedText) != value)
        undo.undo()
        #expect(MessageText(attributedString: composer.textView.attributedText) == value)
        undo.redo()
        #expect(MessageText(attributedString: composer.textView.attributedText) != value)
        undo.undo()
        composer.sendButtonDidTap()
        controller.view.endEditing(true)
        let outgoing = try #require(controller.viewModel.messages.last)
        controller.viewModel.messages.append(.init(id: controller.viewModel.nextMessageID, direction: .incoming,
            content: .richText(value), sentAt: outgoing.sentAt, deliveryState: nil))
        controller.viewModel.nextMessageID += 1
        controller.viewModel.publish(reason: .receivedMessage)
        try await Task.sleep(nanoseconds: 400_000_000)
        controller.view.layoutIfNeeded()
        let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(
            rtl ? "chat-rich-text-rtl.png" : "chat-rich-text.png"))
    }

    @Test func failedRetryRetainsFormattedPayload() async throws {
        guard #available(iOS 26.0, *) else { return }
        let model = ChatViewModel(localizer: Localizer { key, _ in key }, clock: Date.init,
                                  messageSender: SimulatedMessageSender(failsNextSend: true),
                                  sleeper: { try await Task.sleep(for: $0) })
        defer { model.cancelPendingReply() }
        let text = MessageText(runs: [.init("保留删除线", style: .strikethrough)])
        #expect(model.sendContents([.richText(text)]))
        let original = try #require(model.messages.last)
        for _ in 0..<100 where model.messages.last?.deliveryState == .sending {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.messages.last?.deliveryState == .failed)
        #expect(model.retryMessage(id: original.id))
        #expect(model.messages.last?.content == original.content)
        #expect(model.messages.last?.id == original.id)
        #expect(model.messages.last?.sentAt == original.sentAt)
    }

    @Test func bubbleRescalesEveryStyleForDynamicType() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let bubble = TextBubbleView(frame: CGRect(x: 20, y: 100, width: 300, height: 200))
        root.view.addSubview(bubble)
        bubble.traitOverrides.preferredContentSizeCategory = .large
        let text = MessageText(runs: [.init("Bold", style: .bold), .init(" Underline", style: .underline)])
        bubble.configure(.init(id: 1, direction: .incoming, richText: text, deliveryText: nil))
        let initial = try #require(bubble.messageTextView.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        bubble.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(nanoseconds: 50_000_000)
        let updated = try #require(bubble.messageTextView.attributedText)
        let bold = try #require(updated.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let regular = try #require(updated.attribute(.font, at: 5, effectiveRange: nil) as? UIFont)
        #expect(bold.pointSize > initial.pointSize)
        #expect(bold.pointSize == regular.pointSize)
        #expect(MessageText(attributedString: updated) == text)
    }

    @Test func bubbleMeasuresBothDirectionsAndClearsFormattingOnReuse() throws {
        let text = MessageText(runs: [.init("Bold ", style: .bold), .init("Italic 👋\n", style: .italic),
                                      .init("下划线 ", style: .underline), .init("删除线 مرحبا", style: .strikethrough)])
        for direction in [MessageDirection.incoming, .outgoing] {
            let bubble = TextBubbleView(frame: .zero)
            bubble.configure(.init(id: 1, direction: direction, richText: text, deliveryText: nil))
            let value = try #require(bubble.messageTextView.attributedText)
            #expect(MessageText(attributedString: value) == text)
            #expect(value.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == (direction == .outgoing ? .white : .label))
            let wide = bubble.sizeThatFits(CGSize(width: 280, height: 1000))
            let narrow = bubble.sizeThatFits(CGSize(width: 140, height: 1000))
            #expect(wide.height > 30 && narrow.height >= wide.height)
            #expect(bubble.accessibilityLabel == text.text)
            bubble.configure(.init(id: 2, direction: direction, text: "plain", deliveryText: nil))
            #expect(bubble.messageTextView.text == "plain")
            #expect(!bubble.messageTextView.font!.fontDescriptor.symbolicTraits.contains(.traitBold))
            if let attributed = bubble.messageTextView.attributedText {
                #expect(!MessageText(attributedString: attributed).hasFormatting)
            }
            bubble.reset()
            #expect((bubble.messageTextView.attributedText?.length ?? 0) == 0 && bubble.accessibilityLabel == nil)
        }
        let plain = MessagePresentation(id: 1, direction: .incoming, text: text.text, deliveryText: nil)
        let formatted = MessagePresentation(id: 1, direction: .incoming, richText: text, deliveryText: nil)
        #expect(plain.refreshIdentity != formatted.refreshIdentity)
    }
}
