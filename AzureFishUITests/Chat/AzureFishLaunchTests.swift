import XCTest

/// 验证迁移后的正式启动入口和 iOS 15～25 适配入口。
final class AzureFishLaunchTests: XCTestCase {
    /// 普通启动直接展示对应系统版本的页面，并验证聊天输入和发送链路。
    @MainActor func testLaunchRoutesBySystemVersion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-azurefish.locale.identifier", "zh-Hans", "-imessage-basic-history"]
        app.launch()
        if #available(iOS 26.0, *) {
            let editor = app.textViews["imessage.composer.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 15))
            editor.tap()
            editor.typeText("AzureFish migration")
            app.buttons["imessage.composer.send"].tap()
            XCTAssertEqual(editor.value as? String, "")
            XCTAssertTrue(app.collectionViews["imessage.timeline"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["此 iOS 版本的聊天界面待适配。"].waitForExistence(timeout: 10))
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "AzureFish-正式启动入口"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
