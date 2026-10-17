import XCTest

/// 显式连接本机虚构账号服务和真实 Pixabay；普通测试运行默认跳过。
final class ShortVideoLiveUITests: XCTestCase {
    @MainActor func testLivePlaybackPagingAndInteractions() throws {
        guard ProcessInfo.processInfo.environment["AZUREFISH_PIXABAY_UI_LIVE"] == "1" else {
            throw XCTSkip("Requires the fictional loopback server with Pixabay configured")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-local-development", "-azurefish.locale.identifier", "en"]
        app.launch()
        let videos = app.tabBars.buttons["Short videos"]
        if !videos.waitForExistence(timeout: 5) {
            let register = app.buttons["account.design.register"]
            XCTAssertTrue(register.waitForExistence(timeout: 15)); register.tap()
            func fill(_ id: String, _ value: String, secure: Bool = false) {
                let field = secure ? app.secureTextFields[id] : app.textFields[id]
                XCTAssertTrue(field.waitForExistence(timeout: 10))
                let scroll = app.scrollViews["account.form.scroll"]
                for _ in 0..<5 {
                    let bounds = scroll.frame.insetBy(dx: 0, dy: 4)
                    if field.isHittable && bounds.contains(field.frame) { break }
                    if field.frame.minY < bounds.minY { scroll.swipeDown() } else { scroll.swipeUp() }
                }
                field.tap()
                if secure {
                    let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "關閉"])).firstMatch
                    if close.waitForExistence(timeout: 2) { close.tap() }
                    // 沿用账号联调测试的输入方式，避免再次聚焦触发 Password AutoFill。
                    XCTAssertTrue(app.keys["f"].waitForExistence(timeout: 5))
                    app.typeText(value)
                } else {
                    field.typeText(value)
                }
            }
            fill("account.input.name", "video_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10))
            fill("account.input.nickname", "Fictional video test")
            fill("account.input.password", "fictionalpassword", secure: true)
            app.buttons["Show password"].firstMatch.tap()
            XCTAssertEqual(app.textFields["account.input.password"].value as? String, "fictionalpassword")
            app.buttons["Hide password"].tap()
            fill("account.input.confirm", "fictionalpassword", secure: true)
            register.tap()
        }
        XCTAssertTrue(videos.waitForExistence(timeout: 30)); videos.tap()
        let start = Date()
        let seek = app.sliders["shortVideo.progress"]
        XCTAssertTrue(seek.waitForExistence(timeout: 30))
        func waitFor(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 15) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout), .completed)
        }
        waitFor(NSPredicate(format: "enabled == true"), on: seek, timeout: 120)
        print("Pixabay first playable UI: \(Date().timeIntervalSince(start)) seconds")
        XCTAssertTrue(app.buttons["shortVideo.source"].exists)
        let firstProgress = seek.value as? String ?? ""
        waitFor(NSPredicate(format: "value != %@", firstProgress), on: seek)
        let play = app.buttons["shortVideo.play"]
        let feed = app.collectionViews.firstMatch
        // 中央辅助功能按钮将普通触摸交给列表；单击还需等待双击手势失败。
        feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitFor(NSPredicate(format: "label == %@", "Play"), on: play)
        let pausedProgress = seek.value as? String ?? ""
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", pausedProgress), object: seek)
        advancing.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 2), .completed)
        app.buttons["shortVideo.mute"].tap()
        XCTAssertEqual(app.buttons["shortVideo.mute"].label, "Mute")
        app.buttons["shortVideo.mute"].tap()
        XCTAssertEqual(app.buttons["shortVideo.mute"].label, "Unmute")
        let like = app.buttons["shortVideo.like"]
        let originalLike = like.label
        like.tap()
        waitFor(NSPredicate(format: "label != %@ AND enabled == true", originalLike), on: like)
        like.tap()
        waitFor(NSPredicate(format: "label == %@ AND enabled == true", originalLike), on: like)
        app.buttons["shortVideo.comments"].tap()
        let input = app.textViews["shortVideo.comment.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let comment = "Fictional live check " + UUID().uuidString.prefix(8)
        input.tap()
        // 等待半屏面板与键盘完成焦点切换，再向当前输入焦点发送文本。
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            input.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.typeText(comment)
        app.buttons["shortVideo.comment.send"].tap()
        let posted = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", comment)).firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 20))
        app.buttons["Comment options"].firstMatch.tap()
        app.buttons["Delete comment"].tap()
        app.alerts.buttons["Delete comment"].tap()
        waitFor(NSPredicate(format: "exists == false"), on: posted)
        app.buttons["Close"].tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Pixabay live playback"; shot.lifetime = .keepAlways; add(shot)
        let author = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '@'")).firstMatch.label
        feed.swipeUp()
        waitFor(NSPredicate(format: "enabled == true"), on: seek, timeout: 120)
        // 同一作者可能连续出现，翻页证据由截图和滑动后的播放进度共同保留。
        print("Pixabay first author: \(author)")
        if play.label == "Play" {
            feed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            waitFor(NSPredicate(format: "label == %@", "Pause"), on: play)
        }
        let nextProgress = seek.value as? String ?? ""
        waitFor(NSPredicate(format: "value != %@", nextProgress), on: seek)
        let next = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        next.name = "Pixabay live next page"; next.lifetime = .keepAlways; add(next)
    }
}
