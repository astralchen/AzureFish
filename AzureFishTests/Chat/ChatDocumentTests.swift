import Testing
import UIKit
import UniformTypeIdentifiers
import QuickLayoutKit
@testable import AzureFish

@MainActor
@Suite(.serialized, .enabled(if: ChatTestAvailability.isSupported))
struct ChatDocumentTests {
    @Test(arguments: [false, true])
    func documentBodyMeasuresBeforeLayoutAndAdaptsToAvailableWidth(rtl: Bool) throws {
        guard #available(iOS 26.0, *) else { return }
        let cell = DocumentBubbleCell(frame: .zero)
        cell.semanticContentAttribute = rtl ? .forceRightToLeft : .forceLeftToRight
        let file = FileAttachment(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/body-sizing.m4a"),
            displayName: "Audio Message with a very long filename that must wrap.m4a",
            typeIdentifier: UTType.mpeg4Audio.identifier, byteCount: 83_000)
        for incoming in [true, false] {
            cell.configure(.init(id: 1, direction: incoming ? .incoming : .outgoing,
                attachment: .file(file), deliveryText: incoming ? nil : "已读"))
            // 先测量，再改变 bounds；覆盖零尺寸首次测量、收窄和重新展开。
            for width: CGFloat in [402, 200, 320] {
                let proposed = CGSize(width: width, height: 52)
                let measured = cell.sizeThatFits(proposed)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: .init(item: 0, section: 0))
                attributes.size = proposed
                let fitted = cell.preferredLayoutAttributesFitting(attributes)
                #expect(abs(fitted.size.height - measured.height) < 1)
                #expect(measured.height >= 88)
                cell.frame.size = measured
                cell.setNeedsQuickLayout()
                cell.layoutIfNeeded()
                let card = cell.card.convert(cell.card.bounds, to: cell)
                #expect(card.minX >= 12 - 1 && card.maxX <= width - 12 + 1)
                #expect(card.width <= width * 0.70 + 1)
                #expect(card.maxY <= measured.height - 2 + 1)
                if incoming {
                    let save = cell.saveButton.convert(cell.saveButton.bounds, to: cell)
                    #expect(save.width == 44 && save.height == 44)
                    #expect(save.minX >= 12 - 1 && save.maxX <= width - 12 + 1)
                    let gap = rtl ? card.minX - save.maxX : save.minX - card.maxX
                    #expect(abs(gap - 8) < 1)
                } else {
                    let status = cell.deliveryStatusView.convert(cell.deliveryStatusView.bounds, to: cell)
                    #expect(status.minY >= card.maxY + 3 - 1)
                    #expect(status.maxY <= measured.height - 2 + 1)
                }
            }
        }
    }

    @Test func photoAndAudioDraftUseFullEditorWidthWithoutOverlappingSend() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        root.view.backgroundColor = .systemBackground
        defer { window.isHidden = true; previous?.makeKey() }
        let composer = ComposerView(frame: .init(x: 0, y: 100, width: 402, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        root.view.addSubview(composer)
        func layout() {
            for _ in 0..<3 {
                composer.frame.size.height = composer.intrinsicContentSize.height
                composer.setNeedsQuickLayout()
                composer.layoutIfNeeded()
                composer.textView.layoutIfNeeded()
            }
        }
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            view.subviews.flatMap { child in (child as? T).map { [$0] } ?? descendants(child, of: type) }
        }
        layout()
        let plainEditorWidth = composer.textView.bounds.width
        #expect(composer.textView.becomeFirstResponder())
        let file = FileAttachment(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            displayName: "Audio Message.m4a", typeIdentifier: UTType.mpeg4Audio.identifier, byteCount: 88_000)
        composer.insertDocument(.init(attachment: .file(file)))
        guard case .mediaGroup(let group) = ConversationPreviewData.pastedMediaDrafts[0].attachment else {
            Issue.record("Missing photo fixture"); return
        }
        let photo = try #require(group.items.first)
        composer.applyMediaDraft(.init(groupID: group.id, items: [
            .init(id: photo.id, assetIdentifier: nil, content: .ready(photo))
        ]))
        let selection = composer.textView.selectedRange
        for direction in [UIUserInterfaceLayoutDirection.leftToRight, .rightToLeft] {
            composer.applyLayoutDirection(direction)
            layout()
            let card = try #require(descendants(composer.textView, of: AttachmentCard.self).first)
            let title = try #require(descendants(card, of: UILabel.self).first { $0.text == file.displayName })
            let remove = try #require(descendants(card, of: DraftRemoveButton.self).first)
            #expect(composer.textView.bounds.width >= plainEditorWidth + 47)
            #expect(title.bounds.width >= title.intrinsicContentSize.width - 1)
            #expect(title.bounds.height <= ceil(title.font.lineHeight) + 1)
            #expect(!title.convert(title.bounds, to: card).intersects(remove.convert(remove.bounds, to: card)))
            let cardRect = card.convert(card.bounds, to: composer)
            let sendRect = composer.sendButton.convert(composer.sendButton.bounds, to: composer)
            #expect(sendRect.minY >= cardRect.maxY)
            #expect(composer.bounds.contains(sendRect))
            #expect(composer.textView.selectedRange == selection)
            #expect(composer.textView.isFirstResponder)
            if direction == .leftToRight {
                try await Task.sleep(nanoseconds: 250_000_000)
                layout()
                let capture = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
                    root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
                }
                try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("full-width-audio-draft.png"))
            }
        }
        composer.textView.insertText("补充说明")
        layout()
        let textRect = composer.textView.convert(composer.textView.bounds, to: composer)
        let sendRect = composer.sendButton.convert(composer.sendButton.bounds, to: composer)
        #expect(sendRect.minY >= textRect.maxY - 1)
        #expect(composer.plainDraftText == "补充说明")
        #expect(composer.sendButton.isEnabled)
        composer.removeDocument(file.id, notify: false)
        layout()
        #expect(abs(composer.textView.bounds.width - plainEditorWidth) < 1)
        #expect(composer.textView.isFirstResponder)
    }

    @Test func audioFileCardsHugContentAndReserveRemovalSpaceOnlyForDrafts() throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        root.view.backgroundColor = .systemBackground
        defer { window.isHidden = true; previous?.makeKey() }
        let file = FileAttachment(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/audio.m4a"),
            displayName: "Audio Message.m4a", typeIdentifier: UTType.mpeg4Audio.identifier, byteCount: 76_000)
        let cell = DocumentBubbleCell(frame: .init(x: 0, y: 90, width: 402, height: 100))
        root.view.addSubview(cell)
        cell.configure(.init(id: 1, direction: .outgoing, attachment: .file(file), deliveryText: "已读"))
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
        attributes.size = CGSize(width: 402, height: 100)
        cell.frame.size = cell.preferredLayoutAttributesFitting(attributes).size
        cell.layoutIfNeeded()
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            view.subviews.flatMap { child in
                (child as? T).map { [$0] } ?? descendants(child, of: type)
            }
        }
        let title = try #require(descendants(cell.card, of: UILabel.self).first { $0.text == file.displayName })
        let titleRect = title.convert(title.bounds, to: cell.card)
        let rightGap = cell.card.bounds.maxX - titleRect.maxX
        #expect(rightGap >= 11.5 && rightGap <= 13)
        #expect(abs(title.bounds.width - title.intrinsicContentSize.width) <= 1)
        #expect(cell.card.bounds.width < 402 * 0.70 - 20)
        #expect(abs(cell.card.convert(cell.card.bounds, to: cell).maxX - 390) < 1)
        #expect(cell.card.bounds.height == 84)
        let draft = AttachmentCard(frame: .zero)
        root.view.addSubview(draft)
        draft.configure(.init(attachment: .file(file)))
        draft.remove = {}
        let draftSize = draft.preferredSize(maximumWidth: 350)
        #expect(abs(draftSize.width - cell.card.bounds.width - 32) < 1)
        draft.frame = CGRect(x: 402 - 12 - draftSize.width, y: 230, width: draftSize.width, height: draftSize.height)
        draft.layoutIfNeeded()
        let button = try #require(descendants(draft, of: DraftRemoveButton.self).first)
        #expect(button.bounds.size == CGSize(width: 44, height: 44))
        let buttonRect = button.convert(button.bounds, to: draft)
        let draftTitle = try #require(descendants(draft, of: UILabel.self).first { $0.text == file.displayName })
        let draftTitleRect = draftTitle.convert(draftTitle.bounds, to: draft)
        #expect(abs(buttonRect.minX - draftTitleRect.maxX) <= 1)
        // 18 pt 圆形位于右侧 8 pt 处，文字到可见按钮的间距为 18 pt。
        let visibleButtonMinX = draft.bounds.maxX - 8 - 18
        #expect(abs(visibleButtonMinX - draftTitleRect.maxX - 18) <= 1)
        for label in descendants(draft, of: UILabel.self) {
            #expect(!label.convert(label.bounds, to: draft).intersects(buttonRect))
        }
        let capture = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
            root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
        }
        try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("audio-card-content-width.png"))
        let longFile = FileAttachment(id: UUID(), fileURL: file.fileURL,
            displayName: "Audio Message with a very long filename that must wrap.m4a",
            typeIdentifier: file.typeIdentifier, byteCount: file.byteCount)
        draft.configure(.init(attachment: .file(longFile)))
        #expect(draft.preferredSize(maximumWidth: 180).width == 180)
        draft.remove = nil
        draft.configure(.init(attachment: .file(file)))
        #expect(draft.preferredSize(maximumWidth: 350).width == cell.card.bounds.width)
    }

    @Test func richAndIconLinksSizeIndependentlyInDraftsAndSentMessages() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        previous?.endEditing(true)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.overrideUserInterfaceStyle = .light
        root.view.backgroundColor = .systemBackground
        defer { window.isHidden = true; previous?.makeKey() }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let imageURL = store.makeFileURL(prefix: "rich-cover", pathExtension: "png")
        let iconURL = store.makeFileURL(prefix: "site-icon", pathExtension: "png")
        for (url, size) in [(imageURL, CGSize(width: 560, height: 280)), (iconURL, CGSize(width: 64, height: 64))] {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(white: 0.97, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIImage(systemName: "apple.logo")?.withTintColor(UIColor(white: 0.65, alpha: 1), renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: size.width / 2 - size.height / 4, y: size.height / 4,
                                     width: size.height / 2, height: size.height / 2))
            }
            try #require(image.pngData()).write(to: url)
        }
        let rich = LinkAttachment(url: URL(string: "https://apple.com.cn")!,
            title: "Apple（中国大陆）- 官方网站", imageURL: imageURL)
        let compact = LinkAttachment(url: URL(string: "https://example.com")!,
            title: "网站", iconURL: iconURL)
        #expect(AzureFish.Attachment.link(compact).localFileURLs == [iconURL])
        let composer = ComposerView(frame: .init(x: 0, y: 420, width: 402, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        root.view.addSubview(composer)
        func layoutComposer() {
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.layoutIfNeeded()
            composer.textView.layoutIfNeeded()
        }
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            view.subviews.flatMap { child in
                (child as? T).map { [$0] } ?? descendants(child, of: type)
            }
        }
        layoutComposer()
        var pendingRich = rich
        pendingRich.imageURL = nil
        composer.insertDocument(.init(attachment: .link(pendingRich)))
        composer.insertDocument(.init(attachment: .link(compact)))
        composer.insertContents([.text("正文")])
        layoutComposer()
        let selection = composer.textView.selectedRange
        let pendingHeight = composer.intrinsicContentSize.height
        // 模拟元数据稍后返回封面：只更新附件身份，不替换正文或选区。
        composer.updateDocument(.init(attachment: .link(rich)))
        layoutComposer()
        #expect(composer.intrinsicContentSize.height > pendingHeight + 60)
        let cells = [rich, compact].enumerated().map { index, link in
            let cell = DocumentBubbleCell(frame: .init(x: 0, y: 70, width: 402, height: 100))
            root.view.addSubview(cell)
            cell.configure(.init(id: index, direction: .outgoing, attachment: .link(link), deliveryText: nil))
            return cell
        }
        for cell in cells { _ = cell.card.preferredSize(maximumWidth: 281) }
        // 先排开气泡，避免测试视图互相遮挡。
        func layoutCells(width: CGFloat = 402) {
            var y: CGFloat = 70
            for (index, cell) in cells.enumerated() {
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
                attributes.size = CGSize(width: width, height: 100)
                let fitted = cell.preferredLayoutAttributesFitting(attributes)
                cell.frame = CGRect(x: 0, y: y, width: width, height: fitted.size.height)
                cell.layoutIfNeeded()
                y += fitted.size.height + 12
            }
        }
        layoutCells()
        layoutComposer()
        let cards = descendants(composer.textView, of: AttachmentCard.self)
        #expect(cards.count == 2)
        let ordered = cards.sorted { $0.convert($0.bounds, to: composer).minY < $1.convert($1.bounds, to: composer).minY }
        let first = try #require(ordered.first)
        let second = try #require(ordered.last)
        #expect(first.bounds.height > second.bounds.height + 60)
        #expect(first.convert(first.bounds, to: composer).maxY <= second.convert(second.bounds, to: composer).minY)
        #expect(composer.textView.selectedRange == selection)
        #expect(composer.plainDraftText == "正文")
        for card in cards {
            let preview = try #require(descendants(card, of: LinkPreviewView.self).first)
            #expect(preview.convert(preview.bounds, to: card) == card.bounds)
            #expect(descendants(card, of: DraftRemoveButton.self).count == 1)
        }
        let iconPreview = try #require(descendants(second, of: LinkPreviewView.self).first)
        #expect(iconPreview.hasSiteIcon)
        #expect(!iconPreview.hasCover)
        for width: CGFloat in [402, 260] {
            var y: CGFloat = 70
            var heights: [CGFloat] = []
            for (index, cell) in cells.enumerated() {
                let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
                attributes.size = CGSize(width: width, height: 100)
                let fitted = cell.preferredLayoutAttributesFitting(attributes)
                cell.frame = CGRect(x: 0, y: y, width: width, height: fitted.size.height)
                cell.layoutIfNeeded()
                cell.card.layoutIfNeeded()
                heights.append(cell.card.bounds.height)
                #expect(cell.card.bounds.width <= width * 0.70 + 1)
                #expect(cell.card.bounds.height + 4 <= fitted.size.height + 1)
                y += fitted.size.height + 12
            }
            #expect(heights[0] > heights[1] + 40)
            if width == 402 {
                root.view.layoutIfNeeded()
                let capture = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
                    root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
                }
                try capture.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("adaptive-link-cards.png"))
            }
        }
    }

    @Test func attachmentThumbnailRoundsTheVisibleImageAfterAspectFitAndReuse() throws {
        guard #available(iOS 26.0, *) else { return }
        let thumbnail = AttachmentThumbnailView(frame: .init(x: 0, y: 0, width: 48, height: 56))
        // 此项只测图片圆角透明度，排除外层阴影在圆角外产生的半透明像素。
        thumbnail.layer.shadowOpacity = 0
        for (imageSize, mode, corner, edge) in [
            (CGSize(width: 120, height: 120), UIView.ContentMode.scaleAspectFit, CGPoint(x: 0, y: 4), CGPoint(x: 24, y: 5)),
            (CGSize(width: 120, height: 280), .scaleAspectFit, CGPoint(x: 12, y: 0), CGPoint(x: 24, y: 1)),
            (CGSize(width: 120, height: 120), .scaleAspectFill, CGPoint(x: 0, y: 0), CGPoint(x: 24, y: 1)),
        ] {
            thumbnail.contentMode = mode
            thumbnail.image = UIGraphicsImageRenderer(size: imageSize).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: imageSize))
            }
            thumbnail.layoutIfNeeded()
            var pixels = [UInt8](repeating: 0, count: 48 * 56 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(
                    data: bytes.baseAddress, width: 48, height: 56, bitsPerComponent: 8,
                    bytesPerRow: 48 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                thumbnail.layer.render(in: context)
            }
            func alpha(_ point: CGPoint) -> UInt8 { pixels[(Int(point.y) * 48 + Int(point.x)) * 4 + 3] }
            #expect(alpha(corner) < 10, "The visible image corner must be transparent")
            #expect(alpha(edge) > 245, "The straight image edge must remain visible")
            #expect(alpha(CGPoint(x: 24, y: 28)) > 245)
        }
    }

    @Test func attachmentRemoveButtonsRespectRoundedCornersAndKeepTheirHitArea() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        window.overrideUserInterfaceStyle = .dark
        root.view.backgroundColor = .systemBackground
        let thumbnailURL = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-audio-audit.png")
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIImage(systemName: "music.note")?.withTintColor(.lightGray, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 25, y: 20, width: 50, height: 60))
        }
        try thumbnail.pngData()?.write(to: thumbnailURL)
        defer { try? FileManager.default.removeItem(at: thumbnailURL) }
        var documents = ConversationPreviewData.documentDrafts
        if case .file(var file) = documents[0].attachment {
            file.thumbnailURL = thumbnailURL
            documents[0] = .init(attachment: .file(file))
        }
        let drafts = documents
            + ConversationPreviewData.pastedMediaDrafts
            + [.init(attachment: .audio(ConversationPreviewData.audioAttachment))]
            + [.init(attachment: .link(.init(
                url: URL(string: "https://example.invalid/audio")!,
                title: "Audio preview", imageURL: thumbnailURL
            )))]
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            view.subviews.flatMap { child in
                (child as? T).map { [$0] } ?? descendants(child, of: type)
            }
        }
        for (direction, style) in [
            (UIUserInterfaceLayoutDirection.leftToRight, UIUserInterfaceStyle.light),
            (.rightToLeft, .dark),
        ] {
            window.overrideUserInterfaceStyle = style
            for width: CGFloat in [248, 180] {
                let cards = drafts.enumerated().map { index, draft in
                    let card = AttachmentCard(frame: .init(
                        x: 20, y: 70 + CGFloat(index) * 96, width: width,
                        height: TextAttachment.height(for: root.traitCollection)
                    ))
                    card.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
                    root.view.addSubview(card)
                    card.configure(draft)
                    return card
                }
                var nextY: CGFloat = 70
                for card in cards {
                    var removals = 0
                    var opens = 0
                    card.remove = { removals += 1 }
                    card.open = { opens += 1 }
                    card.frame = CGRect(origin: CGPoint(x: 20, y: nextY), size: card.preferredSize(maximumWidth: width))
                    nextY = card.frame.maxY + 12
                    card.layoutIfNeeded()
                    let button = try #require(descendants(card, of: DraftRemoveButton.self).first)
                    let circle = try #require(button.subviews.first)
                    let visualFrame = circle.convert(circle.bounds, to: card)
                    let hitFrame = button.convert(button.bounds, to: card)
                    #expect(visualFrame.size == CGSize(width: 18, height: 18))
                    #expect(abs(visualFrame.minY - 8) < 0.5)
                    #expect(abs(card.bounds.maxX - visualFrame.maxX - 8) < 0.5)
                    #expect(hitFrame.size == CGSize(width: 44, height: 44))
                    #expect(card.bounds.contains(hitFrame))
                    let expandedHitPoint = CGPoint(x: hitFrame.minX + 5, y: hitFrame.maxY - 5)
                    #expect(!visualFrame.contains(expandedHitPoint))
                    #expect(card.hitTest(expandedHitPoint, with: nil) === button)
                    if let preview = descendants(card, of: LinkPreviewView.self).first {
                        // 有图与无图链接都铺满背景，不能再次在右侧留出异色删除栏。
                        let previewFrame = preview.convert(preview.bounds, to: card)
                        #expect(previewFrame == card.bounds)
                    }
                    for label in descendants(card, of: UILabel.self) where !label.isHidden && !(label.text ?? "").isEmpty {
                        let labelFrame = label.convert(label.bounds, to: card)
                        #expect(!labelFrame.intersects(hitFrame))
                        #expect(card.bounds.insetBy(dx: -1, dy: -1).contains(labelFrame))
                    }
                    button.sendActions(for: .touchUpInside)
                    #expect(removals == 1 && opens == 0)
                    #expect(card.accessibilityActivate())
                    #expect(opens == 1)
                }
                // 等待窗口提交布局后捕获完整预览。
                try await Task.sleep(nanoseconds: 300_000_000)
                root.view.layoutIfNeeded()
                let name = direction == .rightToLeft ? "rtl" : "ltr"
                let image = UIGraphicsImageRenderer(bounds: root.view.bounds).image { _ in
                    root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("attachment-corner-audit-\(name)-\(Int(width)).png"))
                cards.forEach { $0.removeFromSuperview() }
            }
        }
    }

    @Test func typingAfterLoadedLinksPreservesPreviewViews() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let composer = ComposerView(frame: .init(x: 0, y: 120, width: 402, height: 60))
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let imageURL = store.makeFileURL(prefix: "loaded-link", pathExtension: "png")
        let image = UIGraphicsImageRenderer(size: .init(width: 160, height: 100)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(.init(x: 0, y: 0, width: 160, height: 100))
        }
        try #require(image.pngData()).write(to: imageURL)
        composer.configure(strings: ConversationPreviewData.composerStrings)
        root.view.addSubview(composer)
        func layout() {
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.layoutIfNeeded()
            composer.textView.layoutIfNeeded()
        }
        func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
            view.subviews.flatMap { child in
                (child as? T).map { [$0] } ?? descendants(child, of: type)
            }
        }
        layout()
        for (url, title) in [("https://apple.com", "Apple"), ("https://baidu.com", "百度一下，你就知道")] {
            composer.insertDocument(.init(attachment: .link(.init(url: URL(string: url)!, title: title, imageURL: imageURL))))
        }
        layout()
        #expect(composer.textView.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 300_000_000)
        layout()
        let originalCards = descendants(composer.textView, of: AttachmentCard.self)
        #expect(originalCards.count == 2)
        let originalLinks = originalCards.flatMap { descendants($0, of: LinkPreviewView.self) }
        #expect(originalLinks.count == 2)
        let originalIDs = Set(originalLinks.map(ObjectIdentifier.init))
        for character in "The only way I could do that was if you had to do a lot more work" {
            composer.textView.insertText(String(character))
            layout()
            await Task.yield()
            let links = descendants(composer.textView, of: LinkPreviewView.self)
            #expect(Set(links.map(ObjectIdentifier.init)) == originalIDs)
        }
        for _ in 0..<20 {
            composer.textView.deleteBackward()
            layout()
            await Task.yield()
            #expect(Set(descendants(composer.textView, of: LinkPreviewView.self).map(ObjectIdentifier.init)) == originalIDs)
        }
        // 编辑附件前的文字会改变 provider 的文档位置，也必须保留预览。
        composer.textView.selectedRange = .init(location: 0, length: 0)
        composer.textView.insertText("prefix\n")
        layout()
        #expect(Set(descendants(composer.textView, of: LinkPreviewView.self).map(ObjectIdentifier.init)) == originalIDs)
        #expect(composer.orderedDocumentIDs.count == 2)
        #expect(composer.textView.isFirstResponder)

        // 同一个附件对象可以出现在另一个文本布局中，两个编辑器不能争用视图。
        let secondEditor = UITextView(usingTextLayoutManager: true)
        secondEditor.frame = composer.frame.offsetBy(dx: 0, dy: 400)
        root.view.addSubview(secondEditor)
        secondEditor.attributedText = composer.textView.attributedText
        secondEditor.layoutIfNeeded()
        let secondLinks = descendants(secondEditor, of: LinkPreviewView.self)
        #expect(secondLinks.count == 2)
        #expect(Set(secondLinks.map(ObjectIdentifier.init)).isDisjoint(with: originalIDs))
        #expect(Set(descendants(composer.textView, of: LinkPreviewView.self).map(ObjectIdentifier.init)) == originalIDs)

        // 元数据真正变化时只更新对应卡片，另一张已加载预览保持不变。
        let firstID = try #require(composer.orderedDocumentIDs.first)
        let attachment = try #require(composer.textAttachments[firstID])
        guard case .link(var updatedLink) = attachment.draft.attachment else {
            Issue.record("Missing link draft"); return
        }
        updatedLink.title = "Updated Apple"
        composer.updateDocument(.init(attachment: .link(updatedLink)))
        layout()
        let updatedLinks = descendants(composer.textView, of: LinkPreviewView.self)
        #expect(updatedLinks.count == 2)
        #expect(updatedLinks.contains { $0.link?.title == "Updated Apple" })
        #expect(Set(updatedLinks.map(ObjectIdentifier.init)).intersection(originalIDs).count == 1)
        composer.removeDocument(firstID, notify: false)
        layout()
        #expect(descendants(composer.textView, of: AttachmentCard.self).count == 1)
        // 另一个编辑器保留旧附件字符时，移除回调也必须同步撤销。
        let removedCard = try #require(descendants(secondEditor, of: AttachmentCard.self)
            .first { $0.accessibilityLabel?.contains("apple.com") == true })
        #expect(!removedCard.accessibilityActivate())
    }

    @Test func batchPublishesPhotosFilesLinksThenTextAndRejectsInvalidFileAtomically() throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let file = try makeFile(in: store)
        let group = MediaGroupAttachment(items: [.init(
            assetIdentifier: nil, originalFileURL: file.fileURL, thumbnailFileURL: file.fileURL,
            pixelSize: CGSize(width: 100, height: 100), kind: .image
        )])
        let link = LinkAttachment(url: URL(string: "https://developer.apple.com")!, title: "Apple Developer")
        let model = ChatViewModel()
        let firstMessageID = model.nextMessageID
        defer { model.cancelPendingReply() }
        var sentUpdates = 0
        model.bind { _, reason in if reason == .sentMessage { sentUpdates += 1 } }
        let attachments: [AzureFish.Attachment] = [.mediaGroup(group), .file(file), .link(link)]
        #expect(model.sendAttachments(attachments, followedByText: "caption"))
        let messages = model.state.timeline.compactMap { item -> MessagePresentation? in
            guard case .message(let message) = item.content, message.id >= firstMessageID else { return nil }; return message
        }
        #expect(messages.map(\.id) == Array(firstMessageID..<(firstMessageID + 4)))
        #expect(Array(messages.prefix(3)).map(\.content) == attachments.map { .attachment($0) })
        #expect(messages.last?.text == "caption")
        #expect(sentUpdates == 1)
        let previous = model.state
        try FileManager.default.removeItem(at: file.fileURL)
        #expect(!model.sendAttachments([.link(link), .file(file)], followedByText: "keep"))
        #expect(model.state == previous)
        #expect(sentUpdates == 1)
        #expect(!model.sendAttachments([.link(link), .link(link)], followedByText: "duplicate"))
    }

    @Test func multipleInlineAttachmentsPreserveOrderSelectionAndOnlyRemoveDeletedIdentity() {
        guard #available(iOS 26.0, *) else { return }
        let composer = ComposerView(frame: CGRect(x: 0, y: 0, width: 390, height: 80))
        composer.textView.text = "正文"
        composer.textViewDidChange(composer.textView)
        let first = linkDraft("https://example.com/one")
        let second = linkDraft("https://example.com/two")
        composer.textView.selectedRange = NSRange(location: 0, length: 0)
        composer.insertDocument(first)
        composer.textView.selectedRange = NSRange(location: 2, length: 0)
        composer.insertDocument(second)
        composer.insertDocument(second) // 重复导入只更新原身份。
        #expect(composer.orderedDocumentIDs == [first.id, second.id])
        #expect(composer.plainDraftText == "正文")
        var deleted: [UUID] = []
        composer.actionRequested = { if case .removeDocument(let id) = $0 { deleted.append(id) }; return true }
        let saved = NSAttributedString(attributedString: composer.textView.attributedText)
        composer.textView.textStorage.deleteCharacters(in: NSRange(location: 0, length: 1))
        composer.textViewDidChange(composer.textView)
        #expect(composer.orderedDocumentIDs == [second.id])
        #expect(deleted == [first.id])
        #expect(composer.plainDraftText == "正文")
        composer.textView.attributedText = saved
        composer.textViewDidChange(composer.textView)
        #expect(composer.orderedDocumentIDs == [second.id])
        #expect(deleted == [first.id])
        composer.updateDocument(first) // 迟到回调不能恢复已删除卡片。
        #expect(composer.orderedDocumentIDs == [second.id])
        composer.textView.textStorage.append(NSAttributedString(string: "\u{FFFC}"))
        #expect(composer.plainDraftText == "正文")
    }

    @Test func documentImportCopiesSourceAndCommitRetainsFile() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sourceStore = PageAttachmentStore()
        let store = PageAttachmentStore()
        let controller = DocumentController(store: store)
        defer { controller.discardAll(); store.removeAll(); sourceStore.removeAll() }
        let source = try makeFile(in: sourceStore)
        var inserted: [UUID] = []
        controller.draftInserted = { draft in inserted.append(draft.id) }
        controller.importDocument(source.fileURL)
        let id = try #require(inserted.first)
        #expect(controller.drafts[id]?.status == .importing)
        try await waitUntil { controller.drafts[id]?.status != .importing }
        guard case .file(let file) = controller.drafts[id]?.attachment else { Issue.record("Missing imported file"); return }
        #expect(controller.drafts[id]?.status == .ready)
        #expect(file.fileURL != source.fileURL)
        #expect(try Data(contentsOf: file.fileURL) == Data(contentsOf: source.fileURL))
        #expect(file.byteCount > 0)
        #expect(controller.attachments(for: [id]) != nil)
        controller.commit([id])
        controller.discardAll()
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(controller.drafts.isEmpty)
    }

    @Test func failedImportKeepsExistingAudioAndDeletionCancelsLateCopy() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let controller = DocumentController(store: store)
        defer { controller.discardAll(); store.removeAll() }
        let file = try makeFile(in: store)
        controller.adoptRecording(.init(id: file.id, fileURL: file.fileURL, duration: 2, waveform: [0.3]))
        controller.importDocument(URL(fileURLWithPath: "/missing/never-exists.pdf"))
        let failedID = try #require(controller.drafts.keys.first { $0 != file.id })
        try await waitUntil { controller.drafts[failedID]?.status == .failed }
        #expect(controller.drafts[file.id] != nil)
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(controller.attachments(for: [file.id, failedID]) == nil)
        controller.remove(failedID)
        controller.importDocument(file.fileURL)
        let pendingID = try #require(controller.drafts.keys.first { $0 != file.id })
        let pending = try #require(controller.drafts[pendingID]?.attachment.localFileURLs.first)
        controller.remove(pendingID)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.drafts[pendingID] == nil)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(controller.attachments(for: [file.id]) != nil)
    }

    @Test func linkValidationAndMetadataCancellationKeepNoDeletedDraft() async throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let controller = DocumentController(store: store)
        defer { controller.discardAll(); store.removeAll() }
        #expect(!controller.insertLink(URL(string: "file:///tmp/test")!))
        #expect(!controller.insertLink(URL(string: "javascript:alert(1)")!))
        #expect(controller.insertLink(URL(string: "https://example.invalid/path")!))
        let id = try #require(controller.drafts.keys.first)
        #expect(controller.attachments(for: [id])?.count == 1) // 无元数据时 URL 仍可发送。
        controller.remove(id)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.drafts.isEmpty)
    }

    @Test func failedControllerSendRetainsFileAndBodyThenRetrySendsBoth() throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let audio = AudioController(attachmentStore: store)
        let page = ChatViewController(viewModel: ChatViewModel(), audioController: audio)
        page.loadViewIfNeeded()
        defer { page.documentController.discardAll(); page.viewModel.cancelPendingReply(); store.removeAll() }
        let file = try makeFile(in: store)
        page.documentController.adoptRecording(.init(id: file.id, fileURL: file.fileURL, duration: 2, waveform: [0.3]))
        let composer = page.composerView
        composer.textView.insertText("caption")
        composer.textViewDidChange(composer.textView)
        let data = try Data(contentsOf: file.fileURL)
        try FileManager.default.removeItem(at: file.fileURL)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(composer.orderedDocumentIDs == [file.id])
        #expect(composer.plainDraftText == "caption")
        #expect(page.documentController.drafts[file.id] != nil)
        try data.write(to: file.fileURL)
        composer.sendButton.sendActions(for: .touchUpInside)
        #expect(composer.textAttachments.isEmpty)
        #expect(composer.plainDraftText.isEmpty)
        #expect(page.documentController.drafts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
    }

    @Test func multiTypeCardsInRealWindowFitViewportAndRenderBothDirections() async throws {
        guard #available(iOS 26.0, *) else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let root = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        root.view.backgroundColor = .systemBackground
        let composer = ComposerView(frame: .init(x: 0, y: 120, width: window.bounds.width, height: 60))
        composer.configure(strings: ConversationPreviewData.composerStrings)
        root.view.addSubview(composer)
        for draft in ConversationPreviewData.documentDrafts { composer.insertDocument(draft) }
        composer.textView.insertText("附件之后的正文")
        composer.textViewDidChange(composer.textView)
        for (name, direction, style, large) in [
            ("light-ltr", UIUserInterfaceLayoutDirection.leftToRight, UIUserInterfaceStyle.light, false),
            ("dark-rtl", .rightToLeft, .dark, false),
            ("large-rtl", .rightToLeft, .light, true),
        ] {
            window.overrideUserInterfaceStyle = style
            composer.applyLayoutDirection(direction)
            composer.traitOverrides.preferredContentSizeCategory = large ? .accessibilityExtraExtraExtraLarge : .large
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.setNeedsQuickLayout()
            composer.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            composer.frame.size.height = composer.intrinsicContentSize.height
            composer.layoutIfNeeded()
            #expect(composer.textView.bounds.height <= max(180, window.bounds.height * 0.42) + 1)
            #expect(composer.orderedDocumentIDs.count == 3)
            #expect(composer.sendButton.isEnabled)
            let renderer = UIGraphicsImageRenderer(bounds: root.view.bounds)
            let image = renderer.image { _ in root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true) }
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-documents-\(name).png")
            try image.pngData()?.write(to: output)
        }
        #expect(composer.textView.isScrollEnabled)
        for id in composer.orderedDocumentIDs { composer.removeDocument(id, notify: false) }
        #expect(composer.plainDraftText == "附件之后的正文")
        #expect(composer.intrinsicContentSize.height < 180)
    }

    @Test func inlineSegmentsPreserveWhitespaceAndSplitAtEveryAttachment() {
        guard #available(iOS 26.0, *) else { return }
        let first = linkDraft("https://first.invalid")
        let second = linkDraft("https://second.invalid")
        for prefix in ["", "  A\n", "\n "] {
            for suffix in ["", "\n B  ", " \n"] {
                let composer = ComposerView()
                composer.insertContents([.text(prefix), .attachment(first), .text(" 中间\n "), .attachment(second), .text(suffix)])
                var expected: [DraftSegment] = []
                if !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { expected.append(.text(prefix)) }
                expected += [.attachment(first.id), .text(" 中间\n "), .attachment(second.id)]
                if !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { expected.append(.text(suffix)) }
                #expect(composer.draftSegments == expected)
                #expect(composer.plainDraftText == prefix + " 中间\n " + suffix)
            }
        }
        let composer = ComposerView()
        composer.insertContents([.attachment(first), .text(" \n"), .attachment(second)])
        #expect(composer.draftSegments == [.attachment(first.id), .attachment(second.id)])
    }

    @Test func insertionAtStartMiddleEndAndSelectedAttachmentKeepsOnlyLiveIdentities() {
        guard #available(iOS 26.0, *) else { return }
        for position in [0, 2, 4] {
            let composer = ComposerView()
            composer.textView.text = "ABCD"
            composer.textView.selectedRange = NSRange(location: position, length: 0)
            let first = linkDraft("https://first.invalid")
            let second = linkDraft("https://second.invalid")
            composer.insertContents([.attachment(first), .text(" x "), .attachment(second)])
            var expected: [DraftSegment] = []
            if position > 0 { expected.append(.text(String("ABCD".prefix(position)))) }
            expected += [.attachment(first.id), .text(" x "), .attachment(second.id)]
            if position < 4 { expected.append(.text(String("ABCD".suffix(4 - position)))) }
            #expect(composer.draftSegments == expected)
            #expect(composer.textView.selectedRange == NSRange(location: composer.textView.textStorage.length - (4 - position), length: 0))
            var removed: [UUID] = []
            composer.actionRequested = { if case .removeDocument(let id) = $0 { removed.append(id) }; return true }
            let saved = NSAttributedString(attributedString: composer.textView.attributedText)
            let third = linkDraft("https://third.invalid")
            composer.textView.selectedRange = NSRange(location: 0, length: composer.textView.textStorage.length)
            composer.insertContents([.text("new "), .attachment(third), .text(" end")])
            #expect(Set(removed) == Set([first.id, second.id]))
            #expect(composer.draftSegments == [.text("new "), .attachment(third.id), .text(" end")])
            composer.textView.attributedText = saved
            composer.textViewDidChange(composer.textView)
            #expect(composer.orderedDocumentIDs.isEmpty)
            #expect(!composer.textView.text.contains("\u{FFFC}"))
        }
    }

    @Test func orderedTransactionPreservesTextAndRejectsLateInvalidPayloadAtomically() throws {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        defer { store.removeAll() }
        let file = try makeFile(in: store)
        let link = LinkAttachment(url: URL(string: "https://example.invalid")!)
        let model = ChatViewModel()
        let firstMessageID = model.nextMessageID
        defer { model.cancelPendingReply() }
        var updates = 0
        model.bind { _, reason in if reason == .sentMessage { updates += 1 } }
        let contents: [MessageContent] = [.userText("  A\n"), .attachment(.file(file)), .userText(" B "), .attachment(.link(link)), .userText("\nC  ")]
        #expect(model.sendContents(contents))
        let sent = model.state.timeline.compactMap { item -> MessagePresentation? in
            if case .message(let message) = item.content, message.id >= firstMessageID { return message }; return nil
        }
        #expect(sent.map(\.content) == [.text("  A\n"), .attachment(.file(file)), .text(" B "), .attachment(.link(link)), .text("\nC  ")])
        #expect(updates == 1)
        let snapshot = model.state
        try FileManager.default.removeItem(at: file.fileURL)
        #expect(!model.sendContents([.userText("must not appear"), .attachment(.link(link)), .attachment(.file(file))]))
        #expect(model.state == snapshot)
        #expect(updates == 1)
    }

    @Test func controllerSendsFivePositionedSegmentsAndConvertsURLInPlace() {
        guard #available(iOS 26.0, *) else { return }
        let store = PageAttachmentStore()
        let page = ChatViewController(viewModel: ChatViewModel(), audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        let firstMessageID = page.viewModel.nextMessageID
        defer { page.documentController.discardAll(); page.viewModel.cancelPendingReply(); store.removeAll() }
        page.composerView.textView.text = "  A "
        page.composerView.textView.selectedRange = NSRange(location: 4, length: 0)
        page.documentController.insertPasted([.link(URL(string: "https://first.invalid")!), .text("\nhttps://middle.invalid  "), .link(URL(string: "https://last.invalid")!), .text(" C\n ")])
        let editor = page.composerView
        let segments = editor.draftSegments
        #expect(segments.count == 5)
        // 旧的附件优先请求不能绕过文档快照校验。
        #expect(editor.actionRequested?(.sendDocuments(Array(segments.reversed()))) == false)
        #expect(editor.draftSegments == segments)
        editor.sendButton.sendActions(for: .touchUpInside)
        let sent = page.viewModel.state.timeline.compactMap { item -> MessagePresentation? in
            if case .message(let message) = item.content, message.id >= firstMessageID { return message }; return nil
        }
        #expect(sent.count == 5)
        #expect(sent.first?.text == "  A ")
        #expect(sent.last?.text == " C\n ")
        let urls = sent.compactMap { message -> URL? in
            if case .attachment(.link(let link)) = message.content { return link.url }; return nil
        }
        #expect(urls.map(\.absoluteString) == ["https://first.invalid", "https://middle.invalid", "https://last.invalid"])
        #expect(editor.draftSegments.isEmpty)
    }

    @Test func documentMenuRestoresOriginalSelectionBeforeStartingImports() async throws {
        guard #available(iOS 26.0, *) else { return }
        let sourceStore = PageAttachmentStore()
        let store = PageAttachmentStore()
        let page = ChatViewController(viewModel: ChatViewModel(), audioController: AudioController(attachmentStore: store))
        page.loadViewIfNeeded()
        defer { page.documentController.discardAll(); page.viewModel.cancelPendingReply(); store.removeAll(); sourceStore.removeAll() }
        let file = try makeFile(in: sourceStore)
        let editor = page.composerView
        editor.textView.text = "ABCD"
        editor.textView.selectedRange = NSRange(location: 1, length: 2)
        #expect(editor.actionRequested?(.requestAttachment(kind: .file)) == true)
        // 模态界面接管焦点后，不能使用后来变化的光标。
        editor.textView.selectedRange = NSRange(location: 4, length: 0)
        page.documentController.documentPicker(UIDocumentPickerViewController(forOpeningContentTypes: [.item]), didPickDocumentsAt: [file.fileURL, file.fileURL])
        let ids = editor.orderedDocumentIDs
        try #require(ids.count == 2)
        #expect(editor.draftSegments == [.text("A"), .attachment(ids[0]), .attachment(ids[1]), .text("D")])
        try await waitUntil { ids.allSatisfy { page.documentController.drafts[$0]?.status == .ready } }
        #expect(editor.orderedDocumentIDs == ids)
        #expect(editor.textView.selectedRange == NSRange(location: editor.textView.textStorage.length - 1, length: 0))
    }

    @available(iOS 26.0, *)
    private func makeFile(in store: PageAttachmentStore) throws -> FileAttachment {
        let url = store.makeFileURL(prefix: "fixture", pathExtension: "json")
        let data = Data("{\"message\":\"hello\"}".utf8)
        try data.write(to: url)
        return .init(id: UUID(), fileURL: url, displayName: "Example.json", typeIdentifier: "public.json", byteCount: Int64(data.count))
    }
    @available(iOS 26.0, *)
    private func linkDraft(_ value: String) -> DocumentDraft {
        .init(attachment: .link(.init(url: URL(string: value)!)))
    }
    @available(iOS 26.0, *)
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for document import")
        throw CancellationError()
    }
}
