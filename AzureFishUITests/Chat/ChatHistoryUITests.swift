import XCTest

/// 沿用 ChatRegression 已选择的测试类，验证未带 fixture 参数的正常入口。
extension ChatKeyboardUITests {
    @MainActor func testInitialHistoryStartsAtBottomAndStaysThere() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-azurefish.locale.identifier", "zh-Hans"]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<10 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        let links = app.descendants(matching: .any).matching(identifier: "imessage.attachment.link.card")
        XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 20))
        let firstFrame = links.firstMatch.frame
        for index in 0..<4 {
            saveHistoryScreenshot(app, "entry-stable-\(index)")
            XCTAssertEqual(links.firstMatch.frame.minY, firstFrame.minY, accuracy: 1)
        }
        XCTAssertTrue(app.textViews["imessage.composer.text"].isHittable)
    }

    @MainActor func testInitialHistoryChinese() throws { try checkInitialHistory(locale: "zh-Hans", richText: "混合格式") }
    @MainActor func testInitialHistoryEnglish() throws { try checkInitialHistory(locale: "en", richText: "Combined formatting") }
    @MainActor func testInitialHistoryArabic() throws { try checkInitialHistory(locale: "ar", richText: "تنسيق مختلط") }

    @MainActor private func checkInitialHistory(locale: String, richText: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-azurefish.locale.identifier", locale]
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        XCTAssertTrue(app.collectionViews.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<10 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        let editor = app.textViews["imessage.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let links = app.descendants(matching: .any).matching(identifier: "imessage.attachment.link.card")
        XCTAssertTrue(links.firstMatch.waitForExistence(timeout: 20))
        saveHistoryScreenshot(app, "\(locale)-links")
        var sawFile = false
        var sawAudio = false
        var mediaLabels: Set<String> = []
        let formatted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", richText)).firstMatch
        for _ in 0..<28 {
            let file = app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch
            if !sawFile, file.exists, file.isHittable {
                sawFile = true
                saveHistoryScreenshot(app, "\(locale)-files")
                file.tap()
                XCTAssertTrue(app.otherElements["imessage.preview.pdf"].waitForExistence(timeout: 10))
                saveHistoryScreenshot(app, "\(locale)-pdf-preview")
                app.buttons["imessage.media.preview.close"].tap()
            }
            let audio = app.buttons.matching(identifier: "imessage.audio.play").firstMatch
            if !sawAudio, audio.exists, audio.isHittable {
                sawAudio = true
                saveHistoryScreenshot(app, "\(locale)-audio")
                let playLabel = audio.label
                audio.tap()
                let paused = NSPredicate { _, _ in audio.label != playLabel }
                expectation(for: paused, evaluatedWith: nil)
                waitForExpectations(timeout: 5)
                audio.tap()
            }
            for media in app.descendants(matching: .any).matching(identifier: "imessage.media.message").allElementsBoundByIndex where media.isHittable {
                if mediaLabels.insert(media.label).inserted {
                    saveHistoryScreenshot(app, "\(locale)-\(media.label)")
                }
            }
            if formatted.exists && formatted.isHittable { break }
            app.collectionViews.firstMatch.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(sawFile)
        XCTAssertTrue(sawAudio)
        XCTAssertGreaterThanOrEqual(mediaLabels.count, 3, "Image, video and Live Photo must be reachable")
        XCTAssertTrue(formatted.isHittable)
        saveHistoryScreenshot(app, "\(locale)-rich-text")
        editor.tap()
        editor.typeText("History ready")
        app.buttons["imessage.composer.send"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "History ready")).firstMatch.waitForExistence(timeout: 5))
        saveHistoryScreenshot(app, "\(locale)-sent")
    }

    @MainActor private func saveHistoryScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "InitialHistory-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
