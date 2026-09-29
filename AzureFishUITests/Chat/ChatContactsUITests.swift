import XCTest

final class ChatContactsUITests: XCTestCase {
    @MainActor func testProfileAvatarHasSquareBounds() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-contacts-list", "-details-dark", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        let peer = app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"]
        XCTAssertTrue(peer.waitForExistence(timeout: 25))
        peer.tap()
        let avatar = app.images["contacts.profile.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        XCTAssertEqual(avatar.frame.width, 64, accuracy: 1)
        XCTAssertEqual(avatar.frame.height, 64, accuracy: 1)
        XCTAssertTrue(app.buttons["chat.live.sendMessage"].isHittable)
        capture(app, name: "好友资料-方形头像")
    }

    @MainActor func testRemarkInputSurvivesCompactWideRotation() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-contacts-list", "-azurefish.locale.identifier", "en"]
        app.launch()
        XCTAssertTrue(app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"].waitForExistence(timeout: 25))
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("iPad 窄宽窗口回归") }
        app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"].tap()
        app.buttons["contacts.remark"].tap()
        let editor = app.textFields["contacts.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap(); editor.typeText(" Draft")
        var draft = editor.value as? String
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
        editor.typeText(" Wide")
        draft = (draft ?? "") + " Wide"
        XCTAssertEqual(editor.value as? String, draft)
        capture(app, name: "iPad-宽屏编辑保留")
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(app, landscape: false)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
        editor.typeText(" Narrow")
        XCTAssertEqual(editor.value as? String, (draft ?? "") + " Narrow")
        capture(app, name: "iPad-窄屏编辑保留")
    }
    @MainActor func testContactsProfileRemarkAndBlackListNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-contacts-list", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        let peer = app.cells["contacts.peer.00000000-0000-0000-0000-000000000012"]
        XCTAssertTrue(peer.waitForExistence(timeout: 25))
        XCTAssertFalse(app.cells["contacts.peer.fixture-blocked"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "contacts.footer").count, 1)
        capture(app, name: "通讯录-分组与备注")
        peer.tap()
        XCTAssertTrue(app.buttons["contacts.remark"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.live.sendMessage"].exists)
        XCTAssertFalse(app.buttons["chat.live.deleteFriend"].exists)
        capture(app, name: "通讯录-好友资料")
        app.buttons["contacts.remark"].tap()
        let editor = app.textFields["contacts.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "林沐 · 设计")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons["资料设置"].tap()
        XCTAssertTrue(app.buttons["contacts.block"].waitForExistence(timeout: 5))
        app.buttons["chat.live.deleteFriend"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "通讯录-单向删除确认")
        app.alerts.buttons["取消"].tap()
        app.buttons["应用设置"].firstMatch.tap()
        app.cells["contacts.privacy"].tap()
        app.cells["contacts.blacklist"].tap()
        XCTAssertTrue(app.cells["contacts.peer.fixture-blocked"].waitForExistence(timeout: 5))
        capture(app, name: "通讯录-黑名单")
    }
    @MainActor func testFourLanguagesRequestsAndSearch() throws {
        continueAfterFailure = false
        for language in ["zh-Hans", "zh-Hant", "en", "ar"] {
            let app = XCUIApplication()
            app.launchArguments = ["-chat-details-ui-test", "-contacts-list", "-azurefish.locale.identifier", language]
                + (["zh-Hant", "ar"].contains(language) ? ["-details-dark", "-details-large"] : [])
            app.launch()
            XCTAssertTrue(app.cells["contacts.requests"].waitForExistence(timeout: 25))
            capture(app, name: "通讯录-\(language)")
            app.cells["contacts.requests"].tap()
            XCTAssertTrue(app.cells["contacts.peer.fixture-incoming"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["contacts.accept.fixture-incoming"].exists)
            let footer = app.descendants(matching: .any).matching(identifier: "contacts.footer").firstMatch
            XCTAssertTrue(footer.exists)
            XCTAssertGreaterThanOrEqual(footer.frame.minY, app.cells["contacts.peer.fixture-incoming"].frame.maxY - 1)
            capture(app, name: "新的朋友-\(language)")
            let search = app.searchFields.firstMatch
            search.tap(); search.typeText("NoSuchPerson")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@", "chat.list.state.noResults")).firstMatch.exists || app.otherElements["chat.list.state.noResults"].waitForExistence(timeout: 5))
            capture(app, name: "通讯录-搜索无结果-\(language)")
            app.terminate()
        }
    }
    @MainActor private func waitForOrientation(_ app: XCUIApplication, landscape: Bool) {
        let settled = expectation(for: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }, evaluatedWith: nil)
        wait(for: [settled], timeout: 10)
    }
    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
