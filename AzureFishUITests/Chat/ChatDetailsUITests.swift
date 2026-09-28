import XCTest

final class ChatDetailsUITests: XCTestCase {
    @MainActor func testMembersAndFailedManagementKeepProfile() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 20))
        app.buttons["chat.details.open"].tap()
        app.cells["chat.details.members"].tap()
        XCTAssertTrue(app.cells["chat.details.member.bbbbbbbb-bbbb-4bbb-8bbb-000000000011"].exists)
        app.cells["chat.details.member.bbbbbbbb-bbbb-4bbb-8bbb-000000000001"].tap()
        let remove = app.buttons["移除成员"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.tap()
        app.alerts.buttons["移除成员"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons.firstMatch.tap()
        XCTAssertTrue(remove.isHittable)
    }
    @MainActor func testPushPreferencesSearchOldMessageAndDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        let detail = app.buttons["chat.details.open"]
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        let editor = app.textViews["imessage.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "保留这条草稿")
        detail.tap()
        XCTAssertTrue(app.collectionViews["chat.details.list"].waitForExistence(timeout: 5))
        let pin = app.switches["chat.details.pin.switch"]
        for _ in 0..<3 where !pin.isHittable { app.collectionViews["chat.details.list"].swipeUp() }
        XCTAssertTrue(pin.isHittable)
        pin.tap()
        XCTAssertEqual(pin.value as? String, "1")
        let mute = app.switches["chat.details.mute.switch"]
        mute.tap(); XCTAssertEqual(mute.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "聊天详情-群聊"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.cells["chat.details.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("needle")
        let result = app.cells["chat.row.fixture-2"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "保留这条草稿")
        let old = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "old needle")).firstMatch
        XCTAssertTrue(old.waitForExistence(timeout: 5)); XCTAssertTrue(old.isHittable)
        detail.tap()
        for _ in 0..<3 where !pin.isHittable { app.collectionViews["chat.details.list"].swipeUp() }
        XCTAssertEqual(pin.value as? String, "1"); XCTAssertEqual(mute.value as? String, "1")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["回到最新"].tap()
        let latest = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "周末计划 260")).firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5)); XCTAssertTrue(latest.isHittable)
    }
    @MainActor func testClearConfirmationPreservesPreferencesAndDraft() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-details-ui-test", "-details-direct", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 20))
        app.buttons["chat.details.open"].tap()
        let list = app.collectionViews["chat.details.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let pin = app.switches["chat.details.pin.switch"]
        pin.tap()
        let clear = app.cells["chat.details.clear"]
        for _ in 0..<3 where !clear.isHittable { list.swipeUp() }
        clear.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(clear.exists)
        clear.tap()
        app.alerts.buttons["清空本地聊天记录"].tap()
        XCTAssertEqual(pin.value as? String, "1")
        app.cells["chat.details.search"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("needle")
        XCTAssertFalse(app.cells["chat.row.fixture-2"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.textViews["imessage.composer.text"].value as? String, "保留这条草稿")
    }
    @MainActor func testDirectAndMemberLayouts() throws {
        for flags in [["-details-direct"], ["-details-member"], ["-details-legacy", "-details-direct"]] {
            let app = XCUIApplication()
            app.launchArguments = ["-chat-details-ui-test", "-azurefish.locale.identifier", "ar"] + flags
            app.launch()
            XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 20))
            if flags.contains("-details-legacy"), app.alerts.firstMatch.waitForExistence(timeout: 2) { app.alerts.buttons.firstMatch.tap() }
            app.buttons["chat.details.open"].tap()
            XCTAssertTrue(app.collectionViews["chat.details.list"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.cells["chat.details.dissolve"].exists)
            XCTAssertFalse(app.cells["chat.details.rename"].exists)
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "聊天详情-RTL-\(flags[0])"; image.lifetime = .keepAlways; add(image)
            app.terminate()
        }
    }
    @MainActor func testTraditionalChineseDarkLargeTextAndEnglish() throws {
        for language in ["zh-Hant", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["-chat-details-ui-test", "-azurefish.locale.identifier", language,
                                   "-azurefish.appearance.preference", language == "zh-Hant" ? "dark" : "light"]
            if language == "zh-Hant" { app.launchArguments.append("-details-large") }
            app.launch()
            XCTAssertTrue(app.buttons["chat.details.open"].waitForExistence(timeout: 20))
            app.buttons["chat.details.open"].tap()
            let list = app.collectionViews["chat.details.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let pin = app.switches["chat.details.pin.switch"]
            for _ in 0..<8 where !pin.isHittable { list.swipeUp() }
            XCTAssertTrue(pin.isHittable)
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "聊天详情-\(language)"; image.lifetime = .keepAlways; add(image)
            if language == "en" {
                pin.tap()
                XCUIDevice.shared.orientation = .landscapeLeft
                XCTAssertTrue(list.waitForExistence(timeout: 5))
                for _ in 0..<5 where !pin.isHittable { list.swipeUp() }
                XCTAssertEqual(pin.value as? String, "1")
                XCTAssertLessThanOrEqual(app.cells["chat.details.pin"].frame.width, 642)
                let rotated = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); rotated.name = "聊天详情-宽容器"; rotated.lifetime = .keepAlways; add(rotated)
                XCUIDevice.shared.orientation = .portrait
            }
            app.terminate()
        }
    }

}
