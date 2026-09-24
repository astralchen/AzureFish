import XCTest
import UIKit

/// 通过真实聊天列表检查原内容菜单、完整查看入口和连续开合后的状态恢复。
final class ChatMessageMenuUITests: XCTestCase {
    /// 在不支持聊天演示的系统版本上跳过测试。
    override func setUpWithError() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Chat requires iOS 26 or later") }
    }

    /// 按指定样例和语言启动应用，并导航到聊天页面。
    ///
    /// - Parameters:
    ///   - arguments: 样例或字号参数，默认使用菜单文字样例。
    ///   - locale: 应用文案语言，默认为英语；系统语言固定为英语以稳定系统菜单查询。
    /// - Returns: 已进入聊天页面的测试应用。
    @MainActor private func open(_ arguments: [String] = ["-imessage-menu-fixture"], locale: String = "en") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += arguments + ["-AppleLanguages", "(en)", "-azurefish.locale.identifier", locale]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        let route = app.cells["demo.imessage.title"]
        if arguments.contains("-UIPreferredContentSizeCategoryName") {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("iMessage\n")
        } else {
            for _ in 0..<10 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        XCTAssertTrue(app.textViews["imessage.composer.text"].waitForExistence(timeout: 10))
        return app
    }

    /// 按操作语义查询支持语言中的首个匹配菜单按钮。
    ///
    /// - Parameters:
    ///   - operation: 操作键，例如 `copy`、`share` 或 `save`。
    ///   - app: 正在展示菜单的应用。
    /// - Returns: 匹配按钮的查询结果；调用方应自行等待或断言其存在。
    @MainActor private func menu(_ operation: String, in app: XCUIApplication) -> XCUIElement {
        let titles: [String: [String]] = [
            "copy": ["Copy", "Copy Still Photo", "Copy Transcript", "Copy Link", "拷贝", "拷贝静态照片", "拷贝转写文本", "拷贝链接"],
            "selectText": ["Select Text", "选择文本"], "delete": ["Delete", "删除"],
            "share": ["Share", "Share Originals", "分享", "分享原件", "مشاركة", "مشاركة الملفات الأصلية"],
            "save": ["Save Photo", "Save Animated Image", "Save Live Photo", "Save Video", "Save to Files", "存储照片", "存储动图", "存储实况照片", "存储视频", "存储到文件"]
        ]
        return app.buttons.matching(NSPredicate(format: "label IN %@", titles[operation] ?? [])).firstMatch
    }

    /// 保存全屏截图；名称包含 `preview` 时额外等待绘制稳定，但不替代动画逐帧验收。
    ///
    /// - Parameters:
    ///   - app: 当前场景对应的测试应用。
    ///   - name: 附件名称后缀，用于定位菜单阶段与连续开合次数。
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        if name.contains("preview") {
            let settled = expectation(description: "Preview drawing completes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
            wait(for: [settled], timeout: 2)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "MessageMenu-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 验证富文本复制、删除取消与确认、文字选择及输入草稿保留。
    @MainActor func testTextCopyDeleteCancelAndSelection() throws {
        let app = open()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Bold menu text")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.press(forDuration: 1.1)
        capture(app, "long-press-before-query")
        XCTAssertTrue(menu("copy", in: app).waitForExistence(timeout: 4))
        XCTAssertTrue(menu("selectText", in: app).exists)
        XCTAssertFalse(menu("save", in: app).exists)
        capture(app, "text-menu")
        menu("copy", in: app).tap()
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.press(forDuration: 1.1)
        let paste = app.buttons["Paste"]
        if paste.waitForExistence(timeout: 2) { paste.tap() }
        else { app.menuItems["Paste"].tap() }
        expectation(for: NSPredicate(format: "value == %@", "Bold menu text"), evaluatedWith: editor)
        waitForExpectations(timeout: 5)
        text.press(forDuration: 1.1)
        XCTAssertTrue(menu("delete", in: app).waitForExistence(timeout: 4))
        menu("delete", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(text.exists)
        text.press(forDuration: 1.1)
        XCTAssertTrue(menu("selectText", in: app).waitForExistence(timeout: 4))
        menu("selectText", in: app).tap()
        let copy = app.buttons["Copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 3) || app.menuItems["Copy"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        capture(app, "text-selection")
        editor.tap()
        XCTAssertEqual(editor.value as? String, "Bold menu text")
        text.press(forDuration: 1.1)
        XCTAssertTrue(menu("delete", in: app).waitForExistence(timeout: 4))
        menu("delete", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "label == %@", "Menu text https://www.apple.com")).firstMatch.exists)
        capture(app, "after-delete")
    }

    /// 连续收起同一发出气泡，既检查可访问元素，也检查实际蓝色底图没有丢失。
    @MainActor func testOutgoingTextRepeatedMenuDismissalRestoresBubble() throws {
        let app = open()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Bold menu text")).firstMatch
        try checkRepeatedDismissal(app, text: text)
    }

    /// 使用长文字样例重复收起，检查屏幕边缘气泡的稳定布局和底色恢复。
    @MainActor func testOutgoingLongTextRepeatedMenuDismissalRestoresBubble() throws {
        let app = open(["-imessage-menu-fixture", "-imessage-menu-long-text"])
        let text = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Long message keeps")).firstMatch
        try checkRepeatedDismissal(app, text: text)
    }

    /// 从正常入口分页到录屏中的历史富文本，保持列表已有滚动偏移。
    @MainActor func testOutgoingHistoryTextRepeatedMenuDismissal() throws {
        let app = open([], locale: "zh-Hans")
        let text = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "更早的消息 56")).firstMatch
        for _ in 0..<45 {
            if text.exists, text.isHittable, text.frame.minY > 120,
               text.frame.maxY < app.frame.maxY - 110 { break }
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
        }
        // 录屏中的气泡位于下半屏，系统菜单出现在气泡上方；不能只测菜单在下方的布局。
        for _ in 0..<3 {
            let delta = app.frame.height * 0.69 - text.frame.midY
            if abs(delta) < 25 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45))
            let end = start.withOffset(CGVector(dx: 0, dy: max(-180, min(180, delta))))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        try checkRepeatedDismissal(app, text: text)
    }

    /// 刚发送的普通文字保留键盘，覆盖送达状态变化与屏幕下缘的收起交接。
    @MainActor func testSentTextRepeatedMenuDismissalWithKeyboard() throws {
        let app = open(["-imessage-basic-history"])
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("My outgoing message")
        app.buttons["imessage.composer.send"].tap()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "My outgoing message")).firstMatch
        try checkRepeatedDismissal(app, text: text)
    }

    /// 连续开合八次，核对消息位置和稳定帧中的蓝色气泡覆盖比例。
    ///
    /// 此检查不能捕获关闭动画中的短暂空白，中间帧须结合保留的测试录屏另行检查。
    ///
    /// - Parameters:
    ///   - app: 已打开聊天页面的应用。
    ///   - text: 待长按的发出文字元素，其可见区域用于命中和截图采样。
    /// - Throws: 截图或裁剪图像不可用时抛出测试错误。
    @MainActor private func checkRepeatedDismissal(_ app: XCUIApplication, text: XCUIElement) throws {
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let frame = text.frame
        let visible = frame.intersection(app.frame.insetBy(dx: 0, dy: 150))
        XCTAssertFalse(visible.isEmpty)
        let baseline = try bluePixels(in: visible, app: app)
        XCTAssertGreaterThan(baseline, 100)
        capture(app, "repeated-outgoing-baseline")
        for iteration in 1...8 {
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.midX, dy: visible.midY)).press(forDuration: 0.65)
            XCTAssertTrue(menu("copy", in: app).waitForExistence(timeout: 3), "第 \(iteration) 次菜单")
            dismissMenu(in: app)
            capture(app, "repeated-outgoing-dismiss-\(iteration)")
            XCTAssertEqual(text.frame.minX, frame.minX, accuracy: 1)
            XCTAssertEqual(text.frame.minY, frame.minY, accuracy: 1)
            XCTAssertGreaterThan(try bluePixels(in: visible, app: app), baseline * 8 / 10,
                                 "第 \(iteration) 次收起后蓝色气泡应恢复")
        }
    }

    /// 将指定屏幕区域缩放到 64 × 32 像素，统计满足蓝色阈值的采样点。
    ///
    /// - Parameters:
    ///   - rect: 以屏幕点为单位的采样区域，通过应用宽度换算截图像素比例。
    ///   - app: 提供当前屏幕几何的应用。
    /// - Returns: 蓝色采样点数量，用于与同一消息的基准截图比较。
    /// - Throws: 无法取得或裁剪截图时抛出测试错误。
    @MainActor private func bluePixels(in rect: CGRect, app: XCUIApplication) throws -> Int {
        let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let crop = try XCTUnwrap(image.cropping(to: rect.applying(.init(scaleX: scale, y: scale))))
        var bytes = [UInt8](repeating: 0, count: 64 * 32 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 64, height: 32, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            if blue > red + 60 && blue > green + 25 {
                count += 1
            }
        }
        return count
    }

    /// 验证正文中识别出的链接在长按时使用消息操作菜单。
    @MainActor func testDetectedLinkLongPressUsesMessageMenu() throws {
        let app = open()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Menu text https://www.apple.com")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)).press(forDuration: 1.1)
        XCTAssertTrue(menu("selectText", in: app).waitForExistence(timeout: 4))
        XCTAssertTrue(menu("share", in: app).exists)
        capture(app, "detected-link-menu")
    }

    /// 验证正文链接的普通点击打开系统浏览器，返回应用后消息仍保留。
    @MainActor func testDetectedLinkSingleTapOpensSystemBrowser() throws {
        let app = open()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Menu text https://www.apple.com")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)).tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 8))
        app.activate()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertFalse(menu("selectText", in: app).exists)
    }

    /// 验证菜单操作跟随媒体组当前封面，以及整组删除提示与取消后保留消息的行为。
    @MainActor func testMediaMenuFollowsCoverAndGroupDeletionIsExplicit() throws {
        let app = open(["-imessage-save-fixture", "resources-live"])
        let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        media.press(forDuration: 1.1)
        XCTAssertTrue(menu("save", in: app).waitForExistence(timeout: 4))
        XCTAssertEqual(menu("save", in: app).label, "Save Live Photo")
        XCTAssertEqual(menu("share", in: app).label, "Share Originals")
        capture(app, "live-photo-menu")
        // Outside dismissal must leave the current cover and playback unchanged.
        app.navigationBars.firstMatch.tap()
        media.swipeLeft()
        media.press(forDuration: 1.1)
        XCTAssertTrue(menu("save", in: app).waitForExistence(timeout: 4))
        XCTAssertEqual(menu("save", in: app).label, "Save Photo")
        XCTAssertEqual(menu("share", in: app).label, "Share")
        capture(app, "current-photo-menu")
        menu("delete", in: app).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 4))
        XCTAssertTrue(app.alerts.staticTexts["The entire message and all its items will be removed from the current conversation only."].exists)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(media.exists)
    }

    /// 验证文件菜单的分享操作打开系统分享面板。
    @MainActor func testFileSharePresentsSystemSheet() throws {
        let app = open(["-imessage-save-fixture", "document"])
        let file = app.buttons["imessage.attachment.file.card"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.press(forDuration: 1.1)
        XCTAssertTrue(menu("share", in: app).waitForExistence(timeout: 4))
        XCTAssertFalse(menu("copy", in: app).exists)
        menu("share", in: app).tap()
        XCTAssertTrue(menu("share", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 8))
        capture(app, "file-share")
    }

    /// 验证中文环境下消息操作菜单的本地化标题。
    @MainActor func testChineseMenu() throws {
        let app = open(locale: "zh-Hans")
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Bold menu text")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.press(forDuration: 1.1)
        capture(app, "long-press-before-query")
        XCTAssertTrue(menu("copy", in: app).waitForExistence(timeout: 4))
        XCTAssertEqual(menu("copy", in: app).label, "拷贝")
        XCTAssertEqual(menu("selectText", in: app).label, "选择文本")
        XCTAssertEqual(menu("delete", in: app).label, "删除")
        capture(app, "chinese-menu")
    }
    /// 验证 RTL 和大字号下文字菜单的关键操作仍位于屏幕内。
    @MainActor func testLargeRTLMenuStaysWithinScreen() throws {
        let app = open(["-imessage-menu-fixture", "-UIPreferredContentSizeCategoryName",
                        "UICTContentSizeCategoryAccessibilityXXXL"], locale: "ar")
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Bold menu text")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.press(forDuration: 1.1)
        let select = app.buttons["تحديد النص"]
        XCTAssertTrue(select.waitForExistence(timeout: 4))
        let delete = app.buttons["حذف"]
        XCTAssertTrue(delete.isHittable)
        XCTAssertGreaterThanOrEqual(delete.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(delete.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(delete.frame.maxY, app.frame.maxY)
        capture(app, "large-RTL")
    }

    /// 验证失败消息的重试操作更新原消息，成功后菜单不再提供重试。
    @MainActor func testFailureMenuRetriesSameMessage() throws {
        let app = open(["-imessage-basic-history", "-imessage-fail-first-send"])
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("Retry menu message")
        app.buttons["imessage.composer.send"].tap()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Retry menu message")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        text.press(forDuration: 1.1)
        let retry = app.buttons["Send Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 4))
        capture(app, "failed-message")
        retry.tap()
        XCTAssertTrue(text.exists)
        text.press(forDuration: 1.1)
        XCTAssertTrue(menu("copy", in: app).waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["Send Again"].exists)
    }

    /// 确认系统消息菜单存在且没有独立内容预览，并保存当前画面供视觉检查。
    ///
    /// - Parameters:
    ///   - app: 正在展示菜单的应用。
    ///   - name: 当前场景的截图附件名称。
    @MainActor private func assertOriginalMenu(in app: XCUIApplication, name: String) {
        XCTAssertTrue(menu("share", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "imessage.menu.preview").firstMatch.exists)
        XCTAssertFalse(app.webViews["imessage.menu.preview.web"].exists)
        XCTAssertFalse(app.buttons["imessage.media.preview.close"].exists)
        capture(app, name)
    }

    /// 点击菜单外部并等待菜单消失，同时确认没有衔接完整附件浏览器。
    ///
    /// - Parameter app: 正在展示菜单的应用。
    @MainActor private func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.12)).tap()
        XCTAssertTrue(menu("share", in: app).waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["imessage.media.preview.close"].exists)
    }

    /// 验证各类文件长按保持原卡片位置，收起后普通点击仍能进入完整查看。
    @MainActor func testFileCardsStayOriginalAndOpenOnNormalTap() throws {
        for fixture in ["preview-image-file", "preview-gif-file", "preview-video-file", "document", "audio"] {
            let app = open(["-imessage-save-fixture", fixture])
            let file = app.buttons["imessage.attachment.file.card"]
            XCTAssertTrue(file.waitForExistence(timeout: 15))
            let originalFrame = file.frame
            file.press(forDuration: 1.1)
            assertOriginalMenu(in: app, name: fixture + "-original-card")
            dismissMenu(in: app)
            XCTAssertEqual(file.frame.minY, originalFrame.minY, accuracy: 2)
            capture(app, fixture + "-dismissed")
            if fixture != "audio" {
                file.tap()
                XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
                capture(app, fixture + "-full-view")
                app.buttons["imessage.media.preview.close"].tap()
            }
            app.terminate()
        }
    }

    /// 切换到媒体组第二项后开合菜单，验证正常查看仍从同一项开始。
    @MainActor func testCurrentMediaCardSurvivesMenuAndNormalOpen() throws {
        let app = open(["-imessage-save-fixture", "stack5"])
        let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        media.swipeLeft()
        media.press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "stack-current-card")
        XCTAssertTrue(menu("save", in: app).exists)
        dismissMenu(in: app)
        media.tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["imessage.preview.position"].label, "Item 2 of 5")
        capture(app, "stack-normal-open")
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(media.waitForExistence(timeout: 5))
    }

    /// 检查视频和 Live Photo 的原卡片菜单及收起后的完整查看入口。
    @MainActor func testVideoAndLivePhotoKeepOriginalCardsDuringMenu() throws {
        for fixture in ["resources-draft", "resources-live-audio"] {
            let app = open(["-imessage-save-fixture", fixture])
            let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
            XCTAssertTrue(media.waitForExistence(timeout: 20))
            media.press(forDuration: 1.1)
            assertOriginalMenu(in: app, name: fixture + "-static-card")
            if fixture == "resources-live-audio" { XCTAssertTrue(app.buttons["Share Originals"].exists) }
            dismissMenu(in: app)
            media.tap()
            XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
            capture(app, fixture + "-normal-open")
            app.buttons["imessage.media.preview.close"].tap()
            app.terminate()
        }
    }

    /// 在横屏、RTL 与辅助功能大字号组合下检查媒体菜单，并在结束时恢复竖屏。
    @MainActor func testMediaMenuLandscapeRTLAndLargeText() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = open(["-imessage-save-fixture", "stack5",
                        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], locale: "ar")
        let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 15))
        let visible = media.frame.intersection(app.collectionViews["imessage.timeline"].frame)
        XCTAssertFalse(visible.isNull)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.midY)).press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "landscape-rtl-large-original")
        dismissMenu(in: app)
        XCTAssertTrue(media.exists)
    }

    /// 验证链接卡片长按只显示消息菜单，不创建网页预览。
    @MainActor func testLinkCardDoesNotLoadWebContentOnLongPress() throws {
        let app = open(["-imessage-menu-fixture", "-imessage-menu-web"])
        let card = app.buttons["imessage.attachment.link.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "link-original-card")
        XCTAssertTrue(app.buttons["Open Link"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        dismissMenu(in: app)
        XCTAssertTrue(card.exists)
    }

    /// 在键盘展开时验证行内空白拒绝菜单，而同一行的文字气泡仍可正常长按。
    @MainActor func testBlankRowAreaDoesNotOpenMenuWithKeyboardVisible() throws {
        let app = open()
        let editor = app.textViews["imessage.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let text = app.textViews.matching(NSPredicate(format: "label == %@", "Bold menu text")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 20, dy: text.frame.midY)).press(forDuration: 1.1)
        XCTAssertFalse(menu("share", in: app).exists)
        text.press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "keyboard-original-bubble")
        dismissMenu(in: app)
        capture(app, "keyboard-menu-dismissed")
    }

    /// 从屏幕边缘长文字的可见区域发起菜单，确认收起后原消息仍存在。
    @MainActor func testLongTextKeepsOriginalBubbleAtViewportEdge() throws {
        let app = open(["-imessage-menu-fixture", "-imessage-menu-long-text"])
        let text = app.textViews.matching(NSPredicate(format: "label BEGINSWITH %@", "Long message keeps")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let visible = text.frame.intersection(app.collectionViews["imessage.timeline"].frame)
        XCTAssertFalse(visible.isNull)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.midY)).press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "long-text-edge")
        dismissMenu(in: app)
        XCTAssertTrue(text.exists)
    }

    /// 在语音波形上长按并收起菜单，验证播放按钮状态没有改变。
    @MainActor func testAudioBubbleLongPressDoesNotStartPlayback() throws {
        let app = open(["-imessage-save-fixture", "audio-message"])
        let play = app.buttons["imessage.audio.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let label = play.label
        // 在波形内容处长按；播放按钮保留 UIKit 控件的直接播放语义。
        play.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: 40, dy: 0)).press(forDuration: 1.1)
        assertOriginalMenu(in: app, name: "audio-original-bubble")
        dismissMenu(in: app)
        XCTAssertEqual(play.label, label)
    }

    /// 连续开合带转写的发出语音；保留全程录屏检查收起中间帧，稳定截图只负责几何回归。
    @MainActor func testOutgoingAudioRepeatedMenuDismissalRestoresBubble() throws {
        let app = open(["-imessage-save-fixture", "audio-message", "-imessage-menu-audio-transcript",
                        "-imessage-menu-audio-outgoing"])
        let play = app.buttons["imessage.audio.play"]
        let transcript = app.staticTexts["imessage.audio.transcript"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let frame = transcript.frame
        let baseline = try bluePixels(in: frame, app: app)
        XCTAssertGreaterThan(baseline, 100)
        let label = play.label
        capture(app, "audio-repeated-baseline")
        for iteration in 1...8 {
            play.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
                .withOffset(CGVector(dx: 40, dy: 0)).press(forDuration: 0.65)
            assertOriginalMenu(in: app, name: "audio-repeated-preview-\(iteration)")
            dismissMenu(in: app)
            capture(app, "audio-repeated-dismiss-\(iteration)")
            XCTAssertEqual(play.label, label)
            XCTAssertEqual(transcript.frame.minY, frame.minY, accuracy: 1)
            XCTAssertGreaterThan(try bluePixels(in: frame, app: app), baseline * 8 / 10)
        }
    }

    /// 使用包内生成的实况／GIF 原件，真实等待 Photos 写入成功后的菜单完成反馈。
    @MainActor func testSaveCurrentLivePhotoAndGIFToPhotos() throws {
        guard ProcessInfo.processInfo.environment["CHAT_MENU_PHOTOS_WRITE"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_CHAT_MENU_PHOTOS_WRITE=1; this writes two fixture assets to Photos")
        }
        let app = open(["-imessage-save-fixture", "resources-live"])
        let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 20))
        for title in ["Save Live Photo", "Save Animated Image"] {
            media.press(forDuration: 0.6)
            let save = app.buttons[title]
            XCTAssertTrue(save.waitForExistence(timeout: 4))
            save.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.firstMatch.exists {
                let allow = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", [
                    "Allow Adding Photos", "Allow Adding Photos Only", "Allow Photos to be Added", "Allow Access to Add Photos", "Allow", "OK",
                    "允许添加照片", "仅允许添加照片", "允许添加", "允许", "好"
                ])).firstMatch
                XCTAssertTrue(allow.waitForExistence(timeout: 2))
                allow.tap()
            }
            media.press(forDuration: 0.6)
            XCTAssertTrue(app.buttons["Saved"].exists || app.buttons["Saved"].waitForExistence(timeout: 3), "Photos must report success, not just dismiss the menu")
            capture(app, title == "Save Live Photo" ? "live-photo-saved" : "gif-saved")
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "Completion feedback must restore the save action in the open menu")
            XCTAssertTrue(app.buttons[title].isEnabled)
            app.navigationBars.firstMatch.tap()
            if title == "Save Live Photo" { media.swipeLeft(); media.swipeLeft() }
        }
    }

}
