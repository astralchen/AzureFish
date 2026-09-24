import OSLog
import XCTest

private let logger = Logger(subsystem: "Demo.UITests", category: "ChatKeyboardUITests+TextDetection")

extension ChatKeyboardUITests {
    @MainActor func testDetectedPhoneMenu() throws {
        try verifyDetectedItem("+1 (202) 555-0147", name: "phone", tap: false,
                               expected: ["Call", "FaceTime", "Add to Contacts", "Send Message"])
    }

    @MainActor func testDetectedDateMenu() throws {
        try verifyDetectedItem("tomorrow at 3:30 PM", name: "date", tap: false,
                               expected: ["Create Event", "Add to Calendar", "Show in Calendar", "Create Reminder"])
    }

    @MainActor func testDetectedFlightPreview() throws {
        try verifyDetectedItem("UA123", name: "flight", tap: true,
                               expected: ["Flight", "United", "No Flight Information", "Preview Flight"])
    }

    @MainActor func testDetectedShipmentMenu() throws {
        try verifyDetectedItem("1Z999AA10123456784", name: "shipment", tap: false,
                               expected: ["Track", "UPS", "Shipment", "Package"])
    }

    @MainActor func testDetectedMoneyConversion() throws {
        try verifyDetectedItem("€18.50", name: "money", tap: true,
                               expected: ["USD", "CNY", "Currency", "Convert", "¥", "US$"])
    }

    @MainActor func testDetectedUnitConversion() throws {
        try verifyDetectedItem("72 °F", name: "unit", tap: true,
                               expected: ["22.2", "°C", "Celsius", "Convert"])
    }

    @MainActor
    private func verifyDetectedItem(_ text: String, name: String, tap: Bool, expected: [String]) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-basic-history", "-AppleLanguages", "(en)",
                                "-azurefish.locale.identifier", "en"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        let editor = app.textViews["imessage.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(text)
        app.buttons["imessage.composer.send"].tap()
        let body = app.descendants(matching: .any).matching(identifier: "imessage.message.text")
            .matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        app.collectionViews["imessage.timeline"].swipeDown()
        let target = body.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        if tap { target.tap() } else { target.press(forDuration: 1.2) }
        // 检查系统生成的操作或换算结果，不点击拨号、添加日历等有副作用的最终动作。
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: expected.map {
            NSPredicate(format: "label CONTAINS[cd] %@", $0)
        })
        let nativeAction = app.descendants(matching: .any).matching(predicate).firstMatch
        var recognized = nativeAction.waitForExistence(timeout: 5)
        // 点击没有提供操作时，再验证系统长按菜单；两种手势都交给 UITextView。
        if !recognized && tap {
            target.press(forDuration: 1.2)
            recognized = nativeAction.waitForExistence(timeout: 5)
        }
        logger.notice("DETECTION \(name, privacy: .public): \(recognized ? nativeAction.label : app.debugDescription, privacy: .public)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "System detection - \(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(recognized, "System did not expose the expected \(name) action on this runtime")
    }
}
