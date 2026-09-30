import XCTest

final class AppNavigationUITests: XCTestCase {
    @MainActor func testOfflineContactSendMessageOpensExistingConversation() {
        let app = launchTabs(extraArguments: ["-contacts-send-message"])
        selectTab(app, index: 1)
        let peer = app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"]
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        peer.tap()
        let send = app.buttons["chat.live.sendMessage"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 10))
        XCTAssertFalse(send.exists)
        assertTabs(app, visible: false)
        capture(app, name: "离线好友发消息进入已有会话")
        back(app)
        assertTabs(app, visible: true)
        XCTAssertTrue(app.buttons.matching(identifier: "navigation.tab.0").firstMatch.isSelected)
        // 再次从仍保留的好友详情打开同一会话，验证已有分栏选择也能重新呈现。
        selectTab(app, index: 1)
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 10))
        assertTabs(app, visible: false)
    }

    @MainActor func testContactWithoutLocalConversationOpensEmptyChatAndKeepsDraft() {
        let app = launchTabs(extraArguments: ["-contacts-empty-chat"])
        selectTab(app, index: 1)
        let peer = app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"]
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        peer.tap()
        let send = app.buttons["chat.live.sendMessage"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let composer = app.textViews["imessage.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertFalse(send.exists)
        assertTabs(app, visible: false)
        composer.tap()
        composer.typeText("Local draft")
        capture(app, name: "无历史时本地打开空聊天并编辑草稿")
        back(app)
        assertTabs(app, visible: true)
        selectTab(app, index: 1)
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Local draft")
        assertTabs(app, visible: false)
    }

    @MainActor func testChatDetailPushAndPop() {
        let app = launchTabs()
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        assertTabs(app, visible: true)
        row.tap()
        let details = app.buttons["chat.details.open"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        assertTabs(app, visible: false)
        capture(app, name: "聊天-压入主栈后隐藏底部栏")
        details.tap()
        XCTAssertTrue(app.collectionViews["chat.details.list"].waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        app.cells["chat.details.search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        back(app)
        assertTabs(app, visible: false)
        back(app)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        back(app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        assertTabs(app, visible: true)
        capture(app, name: "聊天-返回会话列表恢复底部栏")
    }

    @MainActor func testContactsDetailPushAndInteractiveReturn() {
        let app = launchTabs()
        selectTab(app, index: 1)
        let peer = app.descendants(matching: .any).matching(identifier: "contacts.peer.00000000-0000-0000-0000-000000000012").firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        assertTabs(app, visible: true)
        peer.tap()
        let remark = app.buttons["contacts.remark"]
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        remark.tap()
        let editor = app.textFields["contacts.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        capture(app, name: "通讯录-非根页隐藏底部栏")

        // 短距离低速拖动应取消返回，仍停留在编辑页。
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        // 继续从详情容器侧滑回主栈根页；取消时底部栏仍隐藏。
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(peer.waitForExistence(timeout: 5))
        assertTabs(app, visible: true)
        capture(app, name: "通讯录-返回列表恢复底部栏")
    }

    @MainActor func testProfileSettingsRootAndPushedAppearance() {
        let app = launchTabs()
        selectTab(app, index: 2)
        let settings = app.cells["account.design.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        assertTabs(app, visible: true)
        settings.tap()
        let appearance = app.cells["account.design.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        appearance.tap()
        XCTAssertTrue(app.cells["account.appearance.system"].waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        back(app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        back(app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        assertTabs(app, visible: true)
        capture(app, name: "我-返回主列表恢复底部栏")
    }

    @MainActor func testSplitRotationPreservesEditorAndBottomBarPolicy() throws {
        let app = launchTabs()
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("需要 iPad 模拟器验证分栏折叠与展开") }
        defer { XCUIDevice.shared.orientation = .portrait }
        selectTab(app, index: 1)
        let peer = app.descendants(matching: .any).matching(identifier: "contacts.peer.00000000-0000-0000-0000-000000000012").firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        peer.tap()
        let remark = app.buttons["contacts.remark"]
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        remark.tap()
        let editor = app.textFields["contacts.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        editor.tap()
        editor.typeText(" Draft")
        let draft = editor.value as? String
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, draft)
        assertTabs(app, visible: false)
        capture(app, name: "iPad-展开后保留编辑与底部栏状态")
        XCUIDevice.shared.orientation = .portrait
        let portrait = NSPredicate { _, _ in app.windows.firstMatch.frame.width < app.windows.firstMatch.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: nil)], timeout: 5), .completed)
        XCTAssertEqual(editor.value as? String, draft)
        back(app)
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 5), .completed)
        XCTAssertTrue(remark.waitForExistence(timeout: 5))
        assertTabs(app, visible: true)
        capture(app, name: "iPad-展开详情根页显示底部栏")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portrait, object: nil)], timeout: 5), .completed)
        assertTabs(app, visible: false)
        back(app)
        XCTAssertTrue(peer.waitForExistence(timeout: 5))
        assertTabs(app, visible: true)
        capture(app, name: "iPad-折叠后返回列表")
    }

    @MainActor func testLaunchIgnoresStoredConversationAndForegroundKeepsOpenPage() {
        let app = launchTabs(extraArguments: ["-navigation-stored-conversation"])
        let row = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'")).firstMatch
        let details = app.buttons["chat.details.open"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        // 本地快照发布后仍停留列表，不能短暂出现列表后又跳入旧详情。
        XCTAssertFalse(details.waitForExistence(timeout: 2))
        assertTabs(app, visible: true)
        row.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        assertTabs(app, visible: false)
        app.terminate()
        app.launch()
        XCTAssertTrue(row.waitForExistence(timeout: 25))
        XCTAssertFalse(details.waitForExistence(timeout: 2))
        assertTabs(app, visible: true)
        capture(app, name: "重新启动停留会话列表")
    }

    @MainActor private func launchTabs(extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-navigation-tabs", "-azurefish.locale.identifier", "zh-Hans"] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons.matching(identifier: "navigation.tab.0").firstMatch.waitForExistence(timeout: 25))
        return app
    }

    @MainActor private func assertTabs(_ app: XCUIApplication, visible: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let tabs = app.buttons.matching(identifier: "navigation.tab.0")
        let predicate = NSPredicate { _, _ in
            tabs.allElementsBoundByIndex.contains(where: { $0.isHittable }) == visible
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, "TabBar visible = \(visible)", file: file, line: line)
    }

    @MainActor private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor private func selectTab(_ app: XCUIApplication, index: Int) {
        // iPad 的系统 TabBar/侧边栏可同时暴露同标识按钮，只操作当前可见实例。
        let query = app.buttons.matching(identifier: "navigation.tab.\(index)")
        let visible = NSPredicate { _, _ in query.allElementsBoundByIndex.contains(where: { $0.isHittable }) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: nil)], timeout: 5), .completed)
        guard let button = query.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("Tab \(index) 没有可点击的按钮")
            return
        }
        button.tap()
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
