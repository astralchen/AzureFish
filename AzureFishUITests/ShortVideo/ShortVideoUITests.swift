import XCTest

/// 使用本地样例验证实际列表、播放器和评论交互，不依赖 Pixabay Key。
final class ShortVideoUITests: XCTestCase {
    @MainActor func testCommentLayoutFollowsLocaleDirection() {
        for locale in ["ar", "en"] {
            let app = XCUIApplication()
            app.launchArguments = ["-short-video-demo", "-azurefish.locale.identifier", locale]
            app.launch()
            XCTAssertTrue(app.buttons["shortVideo.comments"].waitForExistence(timeout: 30))
            app.buttons["shortVideo.comments"].tap()
            let input = app.textViews["shortVideo.comment.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            let send = app.buttons["shortVideo.comment.send"]
            let close = app.buttons[locale == "ar" ? "إغلاق" : "Close"]
            if locale == "ar" {
                XCTAssertLessThan(send.frame.midX, input.frame.midX)
                XCTAssertLessThan(close.frame.midX, input.frame.midX)
            } else {
                XCTAssertGreaterThan(send.frame.midX, input.frame.midX)
                XCTAssertGreaterThan(close.frame.midX, input.frame.midX)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Comment direction \(locale)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    @MainActor func testPlaybackPagingAndCommentDraft() {
        let app = XCUIApplication()
        app.launchArguments = ["-short-video-demo", "-azurefish.locale.identifier", "zh-Hans", "-azurefish.appearance.preference", "dark"]
        app.launch()
        let play = app.buttons["shortVideo.play"]
        guard play.waitForExistence(timeout: 60) else { XCTFail(app.debugDescription); return }
        let seek = app.sliders.firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: seek)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        play.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "播放"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 3), .completed)
        app.buttons["shortVideo.mute"].tap(); XCTAssertEqual(app.buttons["shortVideo.mute"].label, "静音")
        app.buttons["shortVideo.like"].tap()
        let liked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "取消点赞"), object: app.buttons["shortVideo.like"])
        XCTAssertEqual(XCTWaiter.wait(for: [liked], timeout: 5), .completed)
        app.buttons["shortVideo.comments"].tap()
        let input = app.textViews["shortVideo.comment.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["留下你的想法…"].exists)
        XCTAssertFalse(app.buttons["shortVideo.comment.send"].isEnabled)
        input.tap(); input.typeText("test comment")
        app.buttons["shortVideo.comment.send"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "test comment")).firstMatch.waitForExistence(timeout: 5))
        input.tap(); input.typeText("unfinished draft")
        let commentShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); commentShot.name = "Short video comment draft"; commentShot.lifetime = .keepAlways; add(commentShot)
        app.buttons["关闭"].tap()
        app.buttons["shortVideo.comments"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unfinished draft")
        app.buttons["评论选项"].tap()
        app.buttons["删除评论"].tap()
        app.alerts.buttons["删除评论"].tap()
        XCTAssertTrue(app.staticTexts["还没有评论。"].waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "unfinished draft")
        app.buttons["关闭"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let feed = app.collectionViews.firstMatch
        feed.swipeUp()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Fixture creator 2")).firstMatch.waitForExistence(timeout: 5))
        feed.swipeUp(); feed.swipeDown()
        XCTAssertTrue(play.exists)
        let nextReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: seek)
        XCTAssertEqual(XCTWaiter.wait(for: [nextReady], timeout: 30), .completed)
        feed.doubleTap()
        let doubleLiked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "取消点赞"), object: app.buttons["shortVideo.like"])
        XCTAssertEqual(XCTWaiter.wait(for: [doubleLiked], timeout: 5), .completed)
        play.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Short video playback"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["shortVideo.share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 20) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
    }
    @MainActor func testLocalizedPresentationAndDraftRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for (locale, close, theme) in [("zh-Hant", "關閉", "light"), ("en", "Close", "dark"), ("ar", "إغلاق", "light")] {
            XCUIDevice.shared.orientation = .portrait
            let app = XCUIApplication()
            app.launchArguments = ["-short-video-demo", "-azurefish.locale.identifier", locale,
                "-azurefish.appearance.preference", theme]
            if locale == "en" {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            guard app.buttons["shortVideo.comments"].waitForExistence(timeout: 30) else { XCTFail(app.debugDescription); return }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.sliders.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
            app.buttons["shortVideo.play"].tap()
            let feed = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); feed.name = "Short video \(locale) \(theme)"; feed.lifetime = .keepAlways; add(feed)
            app.buttons["shortVideo.comments"].tap()
            let input = app.textViews["shortVideo.comment.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("rotation draft")
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertEqual(input.value as? String, "rotation draft")
            XCUIDevice.shared.orientation = .portrait
            XCTAssertEqual(input.value as? String, "rotation draft")
            let draft = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); draft.name = "Short video comments \(locale)"; draft.lifetime = .keepAlways; add(draft)
            app.buttons[close].tap()
            XCTAssertTrue(app.buttons["shortVideo.play"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }
    @MainActor func testDedicatedVideoTabKeepsInteractionState() {
        let app = XCUIApplication()
        app.launchArguments = ["-short-video-tab-demo", "-azurefish.locale.identifier", "en"]
        app.launch()
        let videoTab = app.buttons.matching(identifier: "app.tab.4").firstMatch
        XCTAssertTrue(videoTab.waitForExistence(timeout: 15)); videoTab.tap()
        XCTAssertTrue(app.staticTexts["Popular"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["shortVideo.back"].exists)
        XCTAssertTrue(app.buttons["shortVideo.more"].exists)
        for identifier in ["shortVideo.more", "shortVideo.mute", "shortVideo.like", "shortVideo.comments", "shortVideo.share"] {
            let button = app.buttons[identifier]
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        XCTAssertEqual(app.buttons["shortVideo.source"].frame.height, 44, accuracy: 1)
        let like = app.buttons["shortVideo.like"]
        XCTAssertTrue(like.waitForExistence(timeout: 30)); like.tap()
        let liked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Unlike"), object: like)
        XCTAssertEqual(XCTWaiter.wait(for: [liked], timeout: 5), .completed)
        app.buttons.matching(identifier: "app.tab.0").firstMatch.tap(); videoTab.tap()
        XCTAssertTrue(like.waitForExistence(timeout: 5)); XCTAssertEqual(like.label, "Unlike")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.sliders.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Short video dedicated tab"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testDiscoverEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["-moments-ui-test", "-azurefish.locale.identifier", "ar", "-azurefish.appearance.preference", "light"]
        app.launch()
        let entry = app.cells["shortVideo.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        XCTAssertTrue(app.otherElements["shortVideo.feed"].waitForExistence(timeout: 5))
        app.buttons["shortVideo.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
}
