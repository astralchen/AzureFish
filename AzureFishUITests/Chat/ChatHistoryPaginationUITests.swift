import XCTest

/// 从正常页面入口验证分页交互，并沿用已有聊天 UI 测试类进入回归测试方案。
extension ChatKeyboardUITests {
    /// 验证中文自动分页、首次更早页失败后的显式重试，以及加载完成后的发送操作。
    @MainActor func testHistoryPaginationChineseWithRetry() throws {
        try verifyHistoryPagination(locale: "zh-Hans", exhausted: "没有更多历史记录", failOnce: true)
    }

    /// 验证英文状态文案、完整分页流程及发送后的底部定位。
    @MainActor func testHistoryPaginationEnglish() throws {
        try verifyHistoryPagination(locale: "en", exhausted: "No more history")
    }

    /// 验证阿拉伯语从右向左布局下的分页、结束提示和输入交互。
    @MainActor func testHistoryPaginationArabic() throws {
        try verifyHistoryPagination(locale: "ar", exhausted: "لا توجد رسائل أقدم")
    }

    /// 以指定语言启动正常会话，通过真实滚动加载到最早记录，并验证仍可发送消息。
    ///
    /// - Parameters:
    ///   - locale: 应用语言标识，用于启动参数与样例消息匹配。
    ///   - exhausted: 当前语言下“没有更多历史记录”的完整文案。
    ///   - failOnce: 是否启用仅一次的更早页故障，并要求实际点击重试按钮。
    @MainActor private func verifyHistoryPagination(locale: String, exhausted: String, failOnce: Bool = false) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-azurefish.locale.identifier", locale]
        if failOnce { app.launchArguments += ["-imessage-history-fail-once"] }
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<10 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        let links = app.descendants(matching: .any).matching(identifier: "imessage.attachment.link.card")
        XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 20))
        capturePagination(app, name: "\(locale)-initial")
        let status = app.descendants(matching: .any).matching(identifier: "imessage.history.status").firstMatch
        let retry = app.buttons["imessage.history.retry"]
        var retried = false
        var savedEarlier = false
        // 限定滚动次数，避免自动加载失效时无限等待；每次用可见状态判断是否结束。
        for _ in 0..<65 {
            if retry.exists && retry.isHittable {
                XCTAssertTrue(failOnce)
                capturePagination(app, name: "\(locale)-failure")
                retry.tap()
                retried = true
            }
            let earlier = app.descendants(matching: .any).matching(NSPredicate(
                format: "label CONTAINS %@", locale == "zh-Hans" ? "更早的消息" : locale == "en" ? "Earlier message" : "رسالة سابقة")).firstMatch
            if !savedEarlier, earlier.exists && earlier.isHittable {
                savedEarlier = true
                capturePagination(app, name: "\(locale)-earlier-page")
            }
            if status.exists && status.isHittable && status.label == exhausted { break }
            app.collectionViews.firstMatch.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(status.isHittable)
        XCTAssertEqual(status.label, exhausted)
        XCTAssertTrue(savedEarlier)
        XCTAssertEqual(retried, failOnce)
        capturePagination(app, name: "\(locale)-exhausted")
        // 到达历史尽头后继续拖动，不应重新进入加载或失败状态。
        app.collectionViews.firstMatch.swipeDown(velocity: .fast)
        XCTAssertEqual(status.label, exhausted)
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("Pagination complete")
        app.buttons["imessage.composer.send"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Pagination complete")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        XCTAssertTrue(sent.isHittable)
        capturePagination(app, name: "\(locale)-sent")
    }

    /// 将真实界面截图永久保留在本次 xcresult 中，便于检查文案、状态与布局方向。
    ///
    /// - Parameters:
    ///   - app: 当前被测应用。
    ///   - name: 包含语言和场景的截图名称后缀。
    @MainActor private func capturePagination(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "HistoryPagination-\(name)"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
