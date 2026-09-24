import XCTest
import UIKit

final class ChatFullscreenUITests: XCTestCase {
    override func setUpWithError() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Chat requires iOS 26") }
        continueAfterFailure = false
    }

    @MainActor func testFullScreenThroughKeyboardAndBack() throws {
        let app = openChat()
        defer { XCUIDevice.shared.orientation = .portrait }
        let list = app.collectionViews["imessage.timeline"]
        let editor = app.textViews["imessage.composer.text"]
        assertFullScreen(list, in: app)
        capture(app, "全屏聊天-竖屏")
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("Full screen\nMultiline message")
        assertFullScreen(list, in: app)
        let composer = app.otherElements["imessage.composer"]
        // 外接键盘下 AX 仍可能保留屏幕外的 Keyboard 节点，不能用 exists 判断停靠键盘。
        let keyboardFrame = app.keyboards.firstMatch.frame.intersection(app.frame)
        let hasSoftwareKeyboard = !keyboardFrame.isNull && keyboardFrame.height > 100
        if hasSoftwareKeyboard {
            XCTAssertLessThanOrEqual(composer.frame.maxY, keyboardFrame.minY + 1)
        } else {
            XCTAssertLessThanOrEqual(composer.frame.maxY, app.frame.maxY)
            XCTAssertTrue(editor.isHittable)
        }
        capture(app, hasSoftwareKeyboard ? "全屏聊天-多行输入与软件键盘" : "全屏聊天-多行输入与外接键盘")
        app.buttons["imessage.composer.send"].tap()
        XCTAssertEqual(editor.value as? String, "")
        // 从列表可见中段向下拖动，验证悬浮输入栏没有接管整个页面的触摸。
        if hasSoftwareKeyboard {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            let hiddenKeyboard = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let keyboard = app.keyboards.firstMatch
                return !keyboard.exists || keyboard.frame.intersection(app.frame).height < 100
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [hiddenKeyboard], timeout: 5), .completed)
        }
        assertFullScreen(list, in: app)
        backButton(in: app).tap()
        XCTAssertTrue(app.cells["demo.imessage.title"].waitForExistence(timeout: 5))
    }

    @MainActor func testFullScreenAfterRotation() throws {
        let app = openChat()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && app.textViews["imessage.composer.text"].isHittable
        }, object: app)
        if XCTWaiter.wait(for: [landscape], timeout: 10) != .completed {
            // Duo 折叠屏与 iPad 窗口都可能维持原尺寸；必须先在首页确认同一限制。
            backButton(in: app).tap()
            XCTAssertTrue(app.cells["demo.imessage.title"].waitForExistence(timeout: 5))
            let mainRotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height
            }, object: app)
            if XCTWaiter.wait(for: [mainRotated], timeout: 5) != .completed {
                throw XCTSkip("宿主窗口在首页和聊天页均未响应设备旋转；窗口尺寸变化另由布局测试覆盖")
            }
            XCTFail("聊天窗口未完成横屏布局")
            return
        }
        assertFullScreen(app.collectionViews["imessage.timeline"], in: app)
        capture(app, "全屏聊天-横屏")
    }

    @MainActor func testDarkLargeRTLFullScreen() {
        let app = openChat(rtl: true)
        assertFullScreen(app.collectionViews["imessage.timeline"], in: app)
        capture(app, "全屏聊天-深色大字体RTL")
    }

    /// 在真实窗口中左右拖动消息列表，消息应保持原有横向位置。
    @MainActor func testHorizontalDraggingPreservesMessagePosition() throws {
        let app = openChat(loadsHistory: true)
        let list = app.collectionViews["imessage.timeline"]
        XCTAssertTrue(list.cells.firstMatch.waitForExistence(timeout: 5))
        let cell = try XCTUnwrap(list.cells.allElementsBoundByIndex.first {
            $0.frame.minY > list.frame.minY + 150 && $0.frame.maxY < list.frame.maxY - 130
        })
        let originalX = cell.frame.minX
        let y = (cell.frame.midY - list.frame.minY) / list.frame.height
        let left = list.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y))
        let right = list.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: y))
        right.press(forDuration: 0.05, thenDragTo: left)
        XCTAssertEqual(cell.frame.minX, originalX, accuracy: 1)
        left.press(forDuration: 0.05, thenDragTo: right)
        XCTAssertEqual(cell.frame.minX, originalX, accuracy: 1)
        assertFullScreen(list, in: app)
        capture(app, "全屏聊天-左右拖动后位置不变")
    }

    @MainActor func testCancelledBackSwipePreservesDraftAndHistory() {
        let app = openChat()
        let editor = app.textViews["imessage.composer.text"]
        editor.tap()
        editor.typeText("History before cancelled back")
        app.buttons["imessage.composer.send"].tap()
        editor.typeText("Preserved draft")
        let list = app.collectionViews["imessage.timeline"]
        let count = list.cells.count
        // 慢速短距离侧滑并停住后松开，使原生返回转场取消。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.002, dy: 0.4))
            .press(forDuration: 0.05,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.4)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "Preserved draft")
        XCTAssertGreaterThanOrEqual(list.cells.count, count)
        assertFullScreen(list, in: app)
        editor.tap()
        editor.typeText(" continues")
        XCTAssertEqual(editor.value as? String, "Preserved draft continues")
        capture(app, "全屏聊天-取消返回后继续编辑")
    }

    /// 先翻看历史再回到底部，覆盖导航栏收起后连续下拉被贴底逻辑打断的路径。
    @MainActor func testPullingDownAfterReturningToBottomMovesMessages() {
        let app = openChat(loadsHistory: true)
        let list = app.collectionViews["imessage.timeline"]
        let card = list.descendants(matching: .any)
            .matching(identifier: "imessage.attachment.file.card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        list.swipeDown()
        for _ in 0..<3 {
            list.swipeUp()
            list.swipeUp()
            XCTAssertTrue(card.isHittable)
            let before = card.frame
            let distance = min(150, list.frame.height * 0.22)
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 12, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertTrue(card.isHittable)
            XCTAssertGreaterThan(card.frame.minY - before.minY, distance * 0.65,
                                 "下拉应持续进入历史，不能在底部附近反复回跳")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "聊天-收起导航栏后连续下拉"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 导航按钮在 Duo 侧栏中的 AX 顺序不同，返回操作须排除语言菜单。
    @MainActor private func backButton(in app: XCUIApplication) -> XCUIElement {
        let sidebarBack = app.buttons["BackButton"]
        if sidebarBack.exists { return sidebarBack }
        return app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "demo.language.menu")).firstMatch
    }

    @MainActor private func openChat(rtl: Bool = false, loadsHistory: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let language = rtl ? "ar" : "zh-Hans"
        app.launchArguments += ["-AppleLanguages", "(\(language))",
                                "-azurefish.locale.identifier", language]
        if loadsHistory {
            app.launchArguments += ["-chat-draft-session", "horizontal-scroll-regression"]
        } else {
            app.launchArguments += ["-imessage-basic-history"]
        }
        if rtl {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                    "-AppleInterfaceStyle", "Dark"]
        }
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<10 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        XCTAssertTrue(app.textViews["imessage.composer.text"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor private func assertFullScreen(_ list: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(list.frame.minX, window.minX, accuracy: 1)
        XCTAssertEqual(list.frame.minY, window.minY, accuracy: 1)
        XCTAssertEqual(list.frame.width, window.width, accuracy: 1)
        XCTAssertEqual(list.frame.height, window.height, accuracy: 1)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        // 捕获实际屏幕，避免旋转后 application 截图仍按旧方向裁切。
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
