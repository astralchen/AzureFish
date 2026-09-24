import XCTest

/// 通过真实界面验证草稿离开恢复、进程重启、附件预览及清空行为，并保留截图证据。
final class ChatDraftUITests: XCTestCase {
    /// 跳过不支持聊天页面的系统，并在首次断言失败后停止当前用例。
    ///
    /// - Throws: 系统低于 iOS 26 时抛出 `XCTSkip`。
    override func setUpWithError() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Chat requires iOS 26") }
        continueAfterFailure = false
    }

    /// 验证长文本返回及重启后完整恢复、键盘保持关闭，继续编辑发送后不再恢复草稿。
    @MainActor func testDraftSurvivesBackAndRelaunchThenSendingClearsIt() {
        let session = "ui-draft-\(UUID().uuidString)"
        let app = launch(session: session)
        let text = "Draft 中文\nLine 2 with spaces  \n" + String(repeating: "Long draft remains editable. ", count: 5)
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText(text)
        app.navigationBars.buttons.firstMatch.tap()
        enterChat(app)
        assertValue(editor, text)
        assertKeyboardHidden(app)
        capture(app, "草稿-返回恢复-长文本")
        // 退后台通知强制提交最新快照，然后终止进程并重新启动。
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        enterChat(app)
        assertValue(editor, text)
        assertKeyboardHidden(app)
        capture(app, "草稿-App重启恢复")
        editor.tap()
        editor.typeText(" continued")
        app.buttons["imessage.composer.send"].tap()
        assertValue(editor, "")
        app.navigationBars.buttons.firstMatch.tap()
        enterChat(app)
        assertValue(editor, "")
        app.terminate()
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        enterChat(app)
        assertValue(editor, "")
        capture(app, "草稿-发送后重启为空")
    }

    /// 验证混合媒体与正文重启后仍可预览和发送，随后重新进入时附件草稿为空。
    @MainActor func testMixedMediaDraftRestoresAfterRelaunchAndCanPreviewAndSend() {
        let session = "ui-media-draft-\(UUID().uuidString)"
        let app = launch(session: session, fixture: true)
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview."))
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 20))
        let count = previews.count
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("照片 GIF Live Photo 视频草稿")
        app.navigationBars.buttons.firstMatch.tap()
        app.terminate()
        app.launchArguments = arguments(session: session)
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        enterChat(app)
        assertValue(editor, "照片 GIF Live Photo 视频草稿")
        XCTAssertEqual(previews.count, count)
        assertKeyboardHidden(app)
        capture(app, "草稿-混合媒体重启恢复")
        previews.firstMatch.tap()
        let close = app.buttons["imessage.media.preview.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        capture(app, "草稿-恢复附件可预览")
        close.tap()
        app.buttons["imessage.composer.send"].tap()
        assertValue(editor, "")
        XCTAssertTrue(previews.firstMatch.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        enterChat(app)
        XCTAssertFalse(previews.firstMatch.exists)
        capture(app, "草稿-混合媒体发送后清空")
    }

    /// 验证取消交互式返回后可以继续编辑，手动全选删除后的空状态可跨页面保留。
    @MainActor func testCancelledBackSwipeKeepsEditingAndManualClearPersists() {
        let app = launch(session: "ui-cancelled-draft-\(UUID().uuidString)")
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("Preserved draft")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.45))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.8)
        assertValue(editor, "Preserved draft")
        editor.tap()
        editor.typeText(" edited")
        capture(app, "草稿-取消返回后继续编辑")
        // 点击输入框后光标位置由 UIKit 决定；通过全选删除验证清空，不能假定光标在末尾。
        editor.press(forDuration: 1.2)
        let selectAll = app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@", ["Select All", "全选", "تحديد الكل"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        assertValue(editor, "")
        app.navigationBars.buttons.firstMatch.tap()
        enterChat(app)
        assertValue(editor, "")
    }

    /// 构造稳定界面语言与独立草稿会话的启动参数。
    ///
    /// - Parameter session: 当前用例独占的会话标识，重启时复用以读取同一草稿。
    /// - Returns: 使用英文系统菜单、中文 Demo 文案和简化历史的启动参数。
    @MainActor private func arguments(session: String) -> [String] {
        ["-AppleLanguages", "(en)", "-azurefish.locale.identifier", "zh-Hans",
         "-imessage-basic-history", "-chat-draft-session", session]
    }

    /// 启动 Demo 并进入可编辑的聊天页面。
    ///
    /// - Parameters:
    ///   - session: 当前用例的独立草稿会话标识。
    ///   - fixture: 是否在首次启动时安装本地混合媒体样例；默认为 `false`，恢复验证时不再注入。
    /// - Returns: 已完成聊天入口导航的应用实例。
    @MainActor private func launch(session: String, fixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(session: session)
        if fixture { app.launchArguments += ["-imessage-save-fixture", "resources-live", "-imessage-preview-draft"] }
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        enterChat(app)
        return app
    }

    /// 在 Demo 列表中定位聊天入口，并等待草稿恢复完成、编辑器可交互。
    ///
    /// - Parameter app: 已启动并停留在 Demo 列表的应用实例。
    @MainActor private func enterChat(_ app: XCUIApplication) {
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<10 where !route.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        let editor = app.textViews["imessage.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in editor.isHittable && editor.isEnabled }, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    /// 最多等待 10 秒，验证编辑器内容与预期字符串完全一致，包括空白和换行。
    ///
    /// - Parameters:
    ///   - editor: 聊天输入文本视图的辅助功能元素。
    ///   - value: 预期正文；空字符串用于验证发送或手动清空后的状态。
    @MainActor private func assertValue(_ editor: XCUIElement, _ value: String) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (editor.value as? String ?? "") == value
        }, object: editor)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 10), .completed)
    }

    /// 验证键盘未占据应用内主要输入区域，允许不可见节点或高度小于 100 点的交叠。
    ///
    /// - Parameter app: 用于读取键盘与应用窗口几何信息的应用实例。
    @MainActor private func assertKeyboardHidden(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(!keyboard.exists || keyboard.frame.intersection(app.frame).height < 100)
    }

    /// 将当前界面截图作为始终保留的 XCTest 附件写入测试结果。
    ///
    /// - Parameters:
    ///   - app: 要捕获当前画面的应用实例。
    ///   - name: 描述验收场景的截图名称。
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
