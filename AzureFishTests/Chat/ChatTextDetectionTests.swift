import AppLocalization
import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatTextDetectionTests {
    /// 文本首次测量、宽窄切换和复用均不依赖列表预先调用 fitting 回调。
    @Test func textCellMeasuresBeforeFittingAcrossWidthsAndReuse() {
        let text = String(repeating: "长文本应按当前容器宽度换行，第一次测量就完整显示。", count: 12)
        for direction in [MessageDirection.incoming, .outgoing] {
            for rtl in [false, true] {
                let cell = TextBubbleCell(frame: .zero)
                cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                cell.configure(.init(id: 1, direction: direction, text: text, deliveryText: "Read"))
                var firstWideSize: CGSize?
                for width: CGFloat in [834, 160, 390, 1210, 834] {
                    let measured = cell.sizeThatFits(CGSize(width: width, height: 52))
                    cell.frame = CGRect(origin: .zero, size: measured)
                    cell.setNeedsQuickLayout()
                    cell.layoutIfNeeded()
                    let bubble = cell.bubbleView.convert(cell.bubbleView.bounds, to: cell)
                    let body = cell.bubbleView.messageTextView
                    #expect(abs(measured.width - width) < 1)
                    #expect(bubble.minX >= 11 && bubble.maxX <= width - 11)
                    let trailing = direction == .outgoing ? !rtl : rtl
                    #expect(abs(trailing ? width - 12 - bubble.maxX : bubble.minX - 12) < 1)
                    #expect(body.contentSize.height <= body.bounds.height + 1)
                    #expect(bubble.width <= 420)
                    if width >= 834 { #expect(bubble.width > 400) }
                    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
                    attributes.size = CGSize(width: width, height: 52)
                    #expect(abs(cell.preferredLayoutAttributesFitting(attributes).size.height - measured.height) < 1)
                    if width == 834 {
                        if let firstWideSize { #expect(measured == firstWideSize) }
                        else { firstWideSize = measured }
                    }
                }
                cell.prepareForReuse()
                cell.configure(.init(id: 2, direction: direction, text: "OK", deliveryText: nil))
                let compact = cell.sizeThatFits(CGSize(width: 834, height: 52))
                cell.frame = CGRect(origin: .zero, size: compact)
                cell.setNeedsQuickLayout()
                cell.layoutIfNeeded()
                #expect(cell.bubbleView.bounds.width < 100)
                #expect(cell.bubbleView.messageTextView.text == "OK")
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "ar"])
    func localizedSamplesKeepAllElevenPairsInOrder(language: String) async throws {
        guard #available(iOS 26.0, *) else { return }
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let localizer = Localizer { key, _ in bundle.localizedString(forKey: key, value: nil, table: nil) }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let history = try await SampleChatHistory.load(store: store, localizer: localizer)
        let names = ["plain", "phone", "address", "url", "email", "date", "flight", "shipment", "money", "physicalValue", "mixed"]
        #expect(history.count == 38)
        for (index, name) in names.enumerated() {
            let key = "imessage.seed.text.\(name)"
            let expected = localizer.text(key)
            #expect(!expected.isEmpty && expected != key)
            #expect(history[index * 2].direction == .incoming)
            #expect(history[index * 2 + 1].direction == .outgoing)
            #expect(history[index * 2].content == .userText(expected))
            #expect(history[index * 2 + 1].content == .userText(expected))
        }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue | NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue)
        let text = names.map { localizer.text("imessage.seed.text.\($0)") }.joined(separator: "\n")
        let results = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        #expect(results.contains { $0.resultType == .phoneNumber })
        #expect(results.contains { $0.resultType == .address })
        #expect(results.contains { $0.url?.scheme == "https" })
        #expect(results.contains { $0.url?.scheme == "mailto" })
        // Foundation 检测语言受当前系统环境影响；英语样例验证日期匹配，其余语言保留系统判定。
        if language == "en" { #expect(results.contains { $0.resultType == .date }) }
        #expect(localizer.text("imessage.seed.text.phone").contains("+86"))
        // 保留完整中文原址，供所有界面语言下的混合文字识别演示使用。
        #expect(localizer.text("imessage.seed.text.address")
            .components(separatedBy: "\n").contains("北京市朝阳区三里屯路19号"))
    }

    @Test func detectorTextFitsBubbleAndClearsOnReuse() throws {
        guard #available(iOS 16.0, *) else { return }
        let message = "电话 +1 (202) 555-0147\n1 Apple Park Way, Cupertino, CA 95014\nhttps://www.apple.com\nhello@example.com\ntomorrow at 3:30 PM\nUA123\n1Z999AA10123456784\nUS$25.00\n10 km; 72 °F"
        for direction in [MessageDirection.incoming, .outgoing] {
            for rtl in [false, true] {
                let bubble = TextBubbleView(frame: .zero)
                bubble.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
                bubble.configure(.init(id: 0, direction: direction, text: message, deliveryText: nil))
                let view = bubble.messageTextView
                #expect(!view.isEditable && view.isSelectable && !view.isScrollEnabled)
                #expect(view.dataDetectorTypes == [.phoneNumber, .link, .address, .calendarEvent,
                    .flightNumber, .shipmentTrackingNumber, .money, .physicalValue])
                #expect(!view.dataDetectorTypes.contains(.lookupSuggestion))
                #expect(view.linkTextAttributes[.foregroundColor] as? UIColor == (direction == .outgoing ? .white : .link))
                let wide = bubble.sizeThatFits(CGSize(width: 280, height: 1000))
                let narrow = bubble.sizeThatFits(CGSize(width: 140, height: 1000))
                #expect(wide.width <= 280 && wide.height > 50)
                #expect(narrow.width <= 140 && narrow.height >= wide.height)
                bubble.configure(.init(id: 1, direction: direction, text: "OK", deliveryText: nil))
                #expect(bubble.sizeThatFits(CGSize(width: 280, height: 1000)).width < 100)
                #expect(view.text == "OK")
                var links = 0
                view.attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: view.attributedText.length)) { value, _, _ in
                    if value != nil { links += 1 }
                }
                #expect(links == 0)
                bubble.reset()
                #expect(view.text.isEmpty && view.accessibilityLabel == nil)
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "ar"])
    func localizedDetectedBubblesRenderInBothDirections(language: String) async throws {
        guard #available(iOS 26.0, *) else { return }
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let history = try await SampleChatHistory.load(store: store,
            localizer: Localizer { key, _ in bundle.localizedString(forKey: key, value: nil, table: nil) })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = ChatViewModel()
        let controller = ChatViewController(viewModel: model)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { model.cancelPendingReply(); window.isHidden = true; previous?.makeKey() }
        model.insertInitialHistory(Array(history[16..<20]))
        try await Task.sleep(nanoseconds: 600_000_000)
        controller.conversationView.applyLayoutDirection(language == "ar" ? .rightToLeft : .leftToRight)
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        let cells = controller.conversationView.collectionView.visibleCells.compactMap { $0 as? TextBubbleCell }
        #expect(cells.count == 4)
        for cell in cells {
            let body = cell.bubbleView.messageTextView
            let center = body.convert(CGPoint(x: body.bounds.midX, y: body.bounds.midY), to: window)
            let hit = window.hitTest(center, with: nil)
            #expect(hit === body || hit?.isDescendant(of: body) == true, "Body hit intercepted by \(String(describing: hit))")
        }
        let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("detected-bubbles-\(language).png"))
        #expect(model.messages.count == 4)
        #expect(model.sendTasks.isEmpty)
    }

    @Test func detectionKeepsRichTextStylesAtAccessibilitySizes() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let bubble = TextBubbleView(frame: .zero)
        root.view.addSubview(bubble)
        let text = MessageText(runs: [.init("https://www.apple.com", style: .bold),
            .init("\nUS$25.00 · 10 km", style: [.italic, .underline]), .init("\nOld price", style: .strikethrough)])
        bubble.configure(.init(id: 1, direction: .incoming, richText: text, deliveryText: nil))
        let regularHeight = bubble.sizeThatFits(CGSize(width: 280, height: 2000)).height
        bubble.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(nanoseconds: 200_000_000)
        bubble.frame = CGRect(origin: CGPoint(x: 20, y: 100),
                              size: bubble.sizeThatFits(CGSize(width: 280, height: 2000)))
        bubble.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(bubble.sizeThatFits(CGSize(width: 280, height: 2000)).height > regularHeight)
        #expect(MessageText(attributedString: bubble.messageTextView.attributedText) == text)
        #expect(bubble.messageTextView.linkTextAttributes[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        let capture = UIGraphicsImageRenderer(bounds: bubble.bounds).image { _ in
            UIColor.systemBackground.setFill()
            UIBezierPath(rect: bubble.bounds).fill()
            bubble.drawHierarchy(in: bubble.bounds, afterScreenUpdates: true)
        }
        try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("detected-rich-accessibility.png"))
    }
}
