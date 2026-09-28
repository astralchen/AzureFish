import XCTest

final class ChatConversationListUITests: XCTestCase {
    @MainActor func testSwipeUnreadHideAndDeleteConfirmation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-details-list", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        let rows = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(app.cells["chat.row.list-empty"].exists)
        let first = rows.element(boundBy: 0)
        XCTAssertTrue(first.label.contains("已置顶"))
        first.swipeLeft()
        XCTAssertTrue(app.buttons["标记未读"].waitForExistence(timeout: 5))
        app.buttons["标记未读"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let unread = NSPredicate(format: "label CONTAINS '已标记为未读'")
        expectation(for: unread, evaluatedWith: first)
        waitForExpectations(timeout: 5)
        capture(app, name: "会话列表-置顶背景与手动未读")
        first.tap()
        XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "NOT (label CONTAINS '已标记为未读')"), evaluatedWith: first)
        waitForExpectations(timeout: 5)
        first.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(rows.count, 2)
        first.swipeLeft(); app.buttons["不显示"].tap()
        let one = NSPredicate(format: "count == 1")
        expectation(for: one, evaluatedWith: rows); waitForExpectations(timeout: 5)
        rows.firstMatch.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["删除"].tap()
        expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: rows)
        waitForExpectations(timeout: 5)
        capture(app, name: "会话列表-全部隐藏后空状态")
    }

    @MainActor func testLocalizedPinnedRows() throws {
        continueAfterFailure = false
        for language in ["zh-Hans", "zh-Hant", "en", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["-chat-details-ui-test", "-details-list", "-azurefish.locale.identifier", language]
                + (["zh-Hant", "ar"].contains(language) ? ["-details-dark", "-details-large"] : [])
            app.launch()
            let rows = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'chat.row.'"))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 20))
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.element(boundBy: 1).label.contains("12"))
            expectation(for: NSPredicate(format: "label CONTAINS %@", "周末计划 260"), evaluatedWith: rows.firstMatch)
            waitForExpectations(timeout: 5)
            capture(app, name: "会话列表-\(language)")
            if language == "ar" { rows.firstMatch.swipeRight() } else { rows.firstMatch.swipeLeft() }
            let hide = ["zh-Hans": "不显示", "zh-Hant": "不顯示", "en": "Hide", "ar": "إخفاء"][language]!
            XCTAssertTrue(app.buttons[hide].waitForExistence(timeout: 5))
            capture(app, name: "会话列表-滑动操作-\(language)")
            app.terminate()
        }
    }
    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
