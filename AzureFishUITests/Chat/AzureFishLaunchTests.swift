import XCTest

/// 验证聊天专用测试入口；正式认证启动另由 AccountFlowUITests 覆盖。
final class AzureFishLaunchTests: XCTestCase {
    /// 显式进入本地聊天回归入口，验证输入和发送链路。
    @MainActor func testLaunchRoutesBySystemVersion() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-chat-ui-test-root", "-azurefish.locale.identifier", "zh-Hans", "-imessage-basic-history"]
        app.launch()
        if #available(iOS 26.0, *) {
            let entry = app.cells["demo.imessage.title"]
            XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
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
        screenshot.name = "AzureFish-聊天回归入口"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
