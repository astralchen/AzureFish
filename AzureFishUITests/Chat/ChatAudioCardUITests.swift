import XCTest
import UIKit

final class ChatAudioCardUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Chat requires iOS 26 or later")
        }
    }

    @MainActor
    func testTypingAfterTwoLoadedLinkPreviews() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-azurefish.locale.identifier", "zh-Hans"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        let route = app.cells["demo.imessage.title"]
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        route.tap()
        let text = app.textViews["imessage.composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        let cards = app.buttons.matching(identifier: "imessage.attachment.link.card")
        for (url, title) in [("https://apple.com", "Apple"), ("https://baidu.com", "百度")] {
            app.buttons["imessage.composer.attachment"].tap()
            app.buttons["链接"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText(url)
            alert.buttons.element(boundBy: 1).tap()
            let loadedCard = cards.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            XCTAssertTrue(loadedCard.waitForExistence(timeout: 25), "Link metadata did not finish loading: \(url)")
        }
        XCTAssertEqual(cards.count, 2)
        let labels = cards.allElementsBoundByIndex.map(\.label).sorted()
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("两个网址预览加载完成")
        text.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.98)).tap()
        let sentence = "The only way I could do that was if you had to do a lot more work"
        text.typeText(sentence)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.allElementsBoundByIndex.map(\.label).sorted(), labels)
        XCTAssertTrue((text.value as? String)?.contains(sentence) == true)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture("连续输入后保留两个已加载网址预览")
        text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        XCTAssertEqual(cards.count, 2)
        XCTAssertTrue((text.value as? String)?.contains(String(sentence.dropLast(20))) == true)
        capture("删除文字后保留网址预览")
    }

    @MainActor
    func testNativeURLPasteAtCaretAndVisibleDeletePreservesBody() throws {
        try verifyNativePaste(language: "zh-Hans", largeText: false)
    }

    @MainActor
    func testNativeURLPasteAndDeleteInLargeRTL() throws {
        try verifyNativePaste(language: "ar", largeText: true)
    }

    @MainActor
    private func verifyNativePaste(language: String, largeText: Bool) throws {
        continueAfterFailure = false
        let pasteboard = UIPasteboard.general
        let originalItems = pasteboard.items
        pasteboard.string = "https://example.com"
        let fixtureChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == fixtureChange { pasteboard.items = originalItems }
        }
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-azurefish.locale.identifier", language]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        route.tap()
        let text = app.textViews["imessage.composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("Keep")
        if largeText {
            text.press(forDuration: 1.2)
        } else {
            text.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.8)).press(forDuration: 1.2)
        }
        func editAction(_ name: String) -> XCUIElement {
            let item = app.menuItems[name]
            for _ in 0..<4 where !item.exists && app.buttons["Back"].exists {
                app.buttons["Back"].tap()
            }
            for _ in 0..<4 where !item.exists && app.buttons["Forward"].exists {
                app.buttons["Forward"].tap()
            }
            return item
        }
        let paste = editAction("Paste")
        XCTAssertTrue(paste.waitForExistence(timeout: 5), app.debugDescription)
        paste.tap()
        let card = app.buttons["imessage.attachment.link.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let body = (text.value as? String)?.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue(body?.contains("Keep") == true)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "原生粘贴与右上角删除-\(language)"
        before.lifetime = .keepAlways
        add(before)
        // 删除按钮物理右上角有独立的 44pt 命中区域；VO 以卡片自定义动作提供。
        card.coordinate(withNormalizedOffset: .zero).withOffset(.init(dx: card.frame.width - 26, dy: 26)).tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue((text.value as? String)?.contains("Keep") == true)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "删除卡片后保留正文和键盘-\(language)"
        after.lifetime = .keepAlways
        add(after)
    }

    @MainActor
    func testPhotosAudioAndTextReceiveThreeSeparatedReplies() throws {
        try verifyPhotoSelection(sendMixed: true)
    }

    @MainActor
    func testPhotoSelectionConvertsPreviewToDeletableTextAttachment() throws {
        try verifyPhotoSelection()
    }

    @MainActor
    func testPhotoSelectionWhileRecordingDiscardsRecording() throws {
        try verifyPhotoSelection(preview: false)
    }

    @MainActor
    func testAudioCardInRTLAtAccessibilityTextSize() throws {
        try verifyPhotoSelection(language: "ar", photosTitle: "الصور", audioTitle: "صوت", largeText: true)
    }

    @MainActor
    func testLinkCardAndTextSendAsSeparateMessages() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-azurefish.locale.identifier", "zh-Hans"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        route.tap()
        let text = app.textViews["imessage.composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["链接"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("https://developer.apple.com")
        alert.buttons.element(boundBy: 1).tap()
        let card = app.buttons["imessage.attachment.link.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        text.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.9)).tap()
        text.typeText("Link caption")
        let draft = XCTAttachment(screenshot: app.screenshot())
        draft.name = "网页附件与正文"
        draft.lifetime = .keepAlways
        add(draft)
        app.buttons["imessage.composer.send"].tap()
        XCTAssertTrue(app.otherElements["Link caption"].waitForExistence(timeout: 10))
        // 回复可能已带回同一链接；全屏列表会同时暴露收发两张卡片。
        let sentCard = app.collectionViews["imessage.timeline"].buttons
            .matching(identifier: "imessage.attachment.link.card").firstMatch
        XCTAssertTrue(sentCard.exists)
        XCTAssertLessThan(sentCard.frame.maxY, text.frame.minY)
        let sent = XCTAttachment(screenshot: app.screenshot())
        sent.name = "先网页附件后正文的独立消息"
        sent.lifetime = .keepAlways
        add(sent)
    }

    @MainActor
    func testInterleavedTextAndAttachmentsSendInEditorOrder() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-azurefish.locale.identifier", "zh-Hans"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        let route = app.cells["demo.imessage.title"]
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        route.tap()
        let text = app.textViews["imessage.composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        text.typeText("Alpha")
        for (url, following, count) in [("https://first.invalid", "Beta", 1), ("https://second.invalid", "Gamma", 2)] {
            app.buttons["imessage.composer.attachment"].tap()
            app.buttons["链接"].tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.textFields.firstMatch.typeText(url)
            alert.buttons.element(boundBy: 1).tap()
            let cards = app.buttons.matching(identifier: "imessage.attachment.link.card")
            XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: cards)], timeout: 10) == .completed)
            // 卡片独立段落后的空行是新的插入位置，由用户点击恢复键盘。
            text.coordinate(withNormalizedOffset: .init(dx: 0.15, dy: 0.98)).tap()
            text.typeText(following)
        }
        let draft = XCTAttachment(screenshot: app.screenshot())
        draft.name = "文字与两个附件交错的草稿"
        draft.lifetime = .keepAlways
        add(draft)
        app.buttons["imessage.composer.send"].tap()
        let alpha = app.otherElements["Alpha"]
        let beta = app.otherElements["Beta"]
        let gamma = app.otherElements["Gamma"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(beta.exists)
        XCTAssertTrue(gamma.exists)
        let cards = app.buttons.matching(identifier: "imessage.attachment.link.card").allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(cards.count, 2)
        XCTAssertLessThan(alpha.frame.maxY, cards[0].frame.minY)
        XCTAssertLessThan(cards[0].frame.maxY, beta.frame.minY)
        XCTAssertLessThan(beta.frame.maxY, cards[1].frame.minY)
        XCTAssertLessThan(cards[1].frame.maxY, gamma.frame.minY)
        let sent = XCTAttachment(screenshot: app.screenshot())
        sent.name = "按位置发送五条独立消息"
        sent.lifetime = .keepAlways
        add(sent)
    }

    @MainActor
    private func verifyPhotoSelection(
        language: String = "zh-Hans", photosTitle: String = "照片", audioTitle: String = "音频",
        largeText: Bool = false, preview: Bool = true, sendMixed: Bool = false
    ) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history"]
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-azurefish.locale.identifier", language]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.exists)
        route.tap()
        let text = app.textViews["imessage.composer.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap()
        let attachmentButton = app.buttons["imessage.composer.attachment"]
        attachmentButton.tap()
        app.buttons[photosTitle].tap()
        XCTAssertTrue(app.scrollViews["photosView_content_scroll_view"].waitForExistence(timeout: 45))
        attachmentButton.tap()
        app.buttons[audioTitle].tap()
        let stop = app.buttons["imessage.composer.recording.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        if preview {
            stop.tap()
            XCTAssertTrue(app.buttons["imessage.composer.audio.play"].waitForExistence(timeout: 10))
        }
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let card = app.buttons["imessage.attachment.file.card"]
        if !preview {
            XCTAssertTrue(stop.waitForNonExistence(timeout: 10))
            XCTAssertFalse(card.exists)
            XCTAssertTrue(app.buttons["imessage.composer.send"].isEnabled)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "录音中选照片后取消录音"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            return
        }
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["imessage.composer.send"])], timeout: 15) == .completed)
        if sendMixed {
            let photos = app.images.matching(identifier: "PXGGridLayout-Info")
            XCTAssertGreaterThanOrEqual(photos.count, 3)
            for index in 1...2 {
                photos.element(boundBy: index).coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
            }
            text.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.98)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            text.typeText("The only")
            app.buttons["imessage.composer.send"].tap()
            let reply = app.otherElements["好呀，一会儿见！"]
            let timeline = app.collectionViews["imessage.timeline"]
            // 交互式收键盘需将手势拖过键盘区域，普通列表内 swipeDown 不够。
            app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.42))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.96)))
            // 外接键盘模式可能保留屏幕外 AX Keyboard 节点；检查实际屏幕遮挡。
            let keyboardHidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let keyboard = app.keyboards.firstMatch
                return !keyboard.exists || keyboard.frame.intersection(app.frame).height < 100
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
            for _ in 0..<3 where !reply.isHittable { timeline.swipeUp() }
            XCTAssertTrue(reply.waitForExistence(timeout: 15))
            let files = app.buttons.matching(identifier: "imessage.attachment.file.card")
                .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
            let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message")
                .allElementsBoundByIndex.sorted { $0.frame.minY < $1.frame.minY }
            let incomingFile = try XCTUnwrap(files.last)
            let incomingMedia = try XCTUnwrap(media.last)
            XCTAssertGreaterThanOrEqual(incomingFile.frame.minY - incomingMedia.frame.maxY, 6)
            XCTAssertGreaterThanOrEqual(reply.frame.minY - incomingFile.frame.maxY, 6)
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "图片音频文字-三条回复保留间距"
            evidence.lifetime = .keepAlways
            add(evidence)
            return
        }
        let picture = XCTAttachment(screenshot: app.screenshot())
        picture.name = "照片与文本音频附件-\(language)"
        picture.lifetime = .keepAlways
        add(picture)
        // 关闭照片面板后，通过真实键盘移动到附件后并删除附件字符。
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        text.typeText("a")
        XCTAssertTrue(app.buttons["imessage.composer.send"].isEnabled)
        text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        XCTAssertTrue(card.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["imessage.composer.send"].isEnabled)
        let deleted = XCTAttachment(screenshot: app.screenshot())
        deleted.name = "键盘删除音频后保留照片-\(language)"
        deleted.lifetime = .keepAlways
        add(deleted)
    }
}
