import XCTest

/// 通过 Debug 样例入口验证导航、媒体交互和布局；不代表真实账号服务联调结果。
final class MomentsUITests: XCTestCase {
    /// 系统裁剪器不可用时跳过裁剪流程，避免把仅验证草稿保留报告为裁剪通过。
    @MainActor func testVideoEditorCropCancellationKeepsDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-moments-video-demo", "-moments-video-editor", "-azurefish.locale.identifier", "zh-Hans", "-azurefish.appearance.preference", "light"]
        app.launch()
        let video = app.buttons["moments.editor.video"]
        XCTAssertTrue(video.waitForExistence(timeout: 60))
        video.tap()
        let trim = app.buttons["裁剪视频"]
        XCTAssertTrue(trim.waitForExistence(timeout: 5)); trim.tap()
        let editor = app.descendants(matching: .any)["moments.video.trimmer"].firstMatch
        if !editor.waitForExistence(timeout: 10) {
            XCTAssertEqual(app.staticTexts["moments.editor.status"].label, "当前设备无法裁剪此视频，原视频已保留。")
            XCTAssertTrue(video.exists)
            XCTAssertTrue(app.buttons["moments.editor.publish"].isEnabled)
            throw XCTSkip("UIVideoEditorController.canEditVideo 返回 false；当前模拟器不能验证系统裁剪，草稿保留已检查。")
        }
        let cancel = editor.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Moments system video editor"; shot.lifetime = .keepAlways; add(shot)
        cancel.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["moments.editor.publish"].isEnabled)
    }

    @MainActor func testVideoPlaybackAndReturnToCachedPoster() {
        let app = XCUIApplication()
        app.launchArguments = ["-moments-video-demo", "-azurefish.locale.identifier", "zh-Hans", "-azurefish.appearance.preference", "light"]
        app.launch()
        let poster = app.buttons["moments.photo.video-fixture.0"]
        XCTAssertTrue(poster.waitForExistence(timeout: 60))
        XCTAssertLessThanOrEqual(poster.frame.width, 280)
        XCTAssertLessThanOrEqual(poster.frame.height, 360)
        let location = poster.frame
        for attempt in 0..<2 {
            poster.tap()
            XCTAssertTrue(app.otherElements["moments.video"].waitForExistence(timeout: 10))
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.progressIndicators["moments.video.progress"])
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 15), .completed)
            XCTAssertFalse(app.buttons["moments.video.retry"].exists)
            XCTAssertFalse(app.buttons["moments.video.close"].exists)
            let dismissButtons = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "Done", "完成"]))
            let close = dismissButtons.firstMatch
            if !close.waitForExistence(timeout: 2) {
                app.otherElements["moments.video"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            }
            XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
            // 暂停中心播放控件，避免截图期间 AVKit 自动收起关闭按钮。
            app.otherElements["moments.video"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertEqual(dismissButtons.count, 1)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Moments video playback \(attempt)"; shot.lifetime = .keepAlways; add(shot)
            close.tap()
            XCTAssertTrue(poster.waitForExistence(timeout: 5))
            XCTAssertEqual(poster.frame.minY, location.minY, accuracy: 2)
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Moments video poster"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testPaginationFooterStates() {
        for state in ["loading", "failed", "ended"] {
            let app = XCUIApplication()
            app.launchArguments = ["-moments-ui-test", "-moments-photo-count", "0", "-moments-pagination-state", state,
                "-azurefish.locale.identifier", "zh-Hans", "-azurefish.appearance.preference", "light"]
            app.launch()
            XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
            let list = app.collectionViews["moments.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let footer = app.descendants(matching: .any).matching(identifier: "moments.pagination." + state).firstMatch
            for _ in 0..<5 where !footer.exists || footer.frame.maxY > app.windows.firstMatch.frame.maxY - 90 { list.swipeUp() }
            XCTAssertTrue(footer.exists)
            XCTAssertEqual(footer.frame.midX, list.frame.midX, accuracy: 1)
            XCTAssertGreaterThanOrEqual(footer.frame.height, 64)
            XCTAssertFalse(app.cells["moments.more"].exists)
            if state == "loading" { XCTAssertTrue(footer.label.contains("正在加载")) }
            if state == "failed" { XCTAssertTrue(footer.label.contains("重试")) }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Moments pagination " + state; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }

    @MainActor func testDiscoverFeedAlbumAndNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["-moments-ui-test", "-azurefish.locale.identifier", "en", "-azurefish.appearance.preference", "light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
        XCTAssertTrue(app.collectionViews["moments.list"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Moments"].waitForExistence(timeout: 5))
        let list = app.collectionViews["moments.list"]
        XCTAssertEqual(list.frame.minX, app.windows.firstMatch.frame.minX, accuracy: 1)
        XCTAssertEqual(list.frame.width, app.windows.firstMatch.frame.width, accuracy: 1)
        XCTAssertTrue(app.buttons["moments.like.00000000-0000-0000-0000-000000000002"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Moments English iPhone"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["陈晨"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Album"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Moments"].exists)
    }
    @MainActor func testNineImagePreview() {
        let app = XCUIApplication(); app.launchArguments = ["-moments-ui-test", "-azurefish.locale.identifier", "en", "-azurefish.appearance.preference", "light"]
        app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
        let first = app.buttons["moments.photo.00000000-0000-0000-0000-000000000002.0"]
        XCTAssertTrue(app.navigationBars["Moments"].waitForExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        for _ in 0..<5 where first.frame.midY > app.windows.firstMatch.frame.maxY - 80 { app.swipeUp() }
        XCTAssertGreaterThan(first.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThan(first.frame.midY, app.windows.firstMatch.frame.maxY)
        XCTAssertTrue(app.buttons["moments.photo.00000000-0000-0000-0000-000000000002.8"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Moments nine image grid"; screenshot.lifetime = .keepAlways; add(screenshot)
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pager = app.collectionViews["moments.photo.pager"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let position = app.staticTexts["moments.photo.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let initialPosition = position.label
        pager.swipeLeft()
        XCTAssertTrue(app.images["moments.preview.image.1"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(position.label, initialPosition)
        let secondPosition = position.label
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, secondPosition)
        XCTAssertGreaterThan(pager.frame.width, pager.frame.height)
        XCUIDevice.shared.orientation = .portrait
        pager.swipeRight()
        XCTAssertTrue(app.images["moments.preview.image.0"].waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, initialPosition)
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "Moments full screen paging"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["moments.photo.close"].tap()
        XCTAssertTrue(app.collectionViews["moments.list"].waitForExistence(timeout: 5))
    }
    @MainActor func testPreviewZoomControlsAndPullDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-moments-ui-test", "-moments-photo-count", "4", "-azurefish.locale.identifier", "en", "-azurefish.appearance.preference", "light"]
        app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
        let first = app.buttons["moments.photo.00000000-0000-0000-0000-000000000002.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        for _ in 0..<5 where first.frame.midY > app.windows.firstMatch.frame.maxY - 80 { app.swipeUp() }
        let anchor = first.frame.minY
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let pager = app.collectionViews["moments.photo.pager"], close = app.buttons["moments.photo.close"]
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let image = app.images["moments.preview.image.0"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap(); XCTAssertFalse(close.isHittable)
        image.tap(); XCTAssertTrue(close.waitForExistence(timeout: 5))
        image.doubleTap(); pager.swipeLeft()
        XCTAssertTrue(app.images["moments.preview.image.0"].exists)
        XCTAssertFalse(app.images["moments.preview.image.1"].isHittable)
        // 保持放大，图片移至右边缘后再次向左滑动即可翻页。
        for _ in 0..<3 where !app.images["moments.preview.image.1"].isHittable { pager.swipeLeft() }
        XCTAssertTrue(app.images["moments.preview.image.1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["moments.preview.image.1"].isHittable)
        let smallStart = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        smallStart.press(forDuration: 0.1, thenDragTo: pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52)))
        XCTAssertTrue(close.waitForExistence(timeout: 5)); XCTAssertTrue(pager.exists)
        let start = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = pager.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.collectionViews["moments.list"].waitForExistence(timeout: 5))
        XCTAssertFalse(pager.exists)
        XCTAssertEqual(first.frame.minY, anchor, accuracy: 2)
    }
    @MainActor func testMenuDismissalAndPreviewReturnKeepFeedPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["-moments-ui-test", "-moments-photo-count", "4", "-azurefish.locale.identifier", "en", "-azurefish.appearance.preference", "light"]
        app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
        let list = app.collectionViews["moments.list"]
        let menu = app.buttons["moments.actions.00000000-0000-0000-0000-000000000002"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        for _ in 0..<5 where !menu.isHittable { list.swipeUp() }
        menu.tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        app.navigationBars["Moments"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 5))
        let photo = app.buttons["moments.photo.00000000-0000-0000-0000-000000000002.0"]
        for _ in 0..<5 where !photo.isHittable { list.swipeDown() }
        let anchor = photo.frame
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["moments.photo.close"].waitForExistence(timeout: 5))
        app.buttons["moments.photo.close"].tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertEqual(photo.frame.minY, anchor.minY, accuracy: 2)
        XCTAssertEqual(photo.frame.width, anchor.width, accuracy: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Moments after menu and preview dismissal"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testSingleAndArabicMiddlePhotoPreview() {
        for (count, language, selected) in [(1, "en", 0), (4, "ar", 2)] {
            let app = XCUIApplication()
            app.launchArguments = ["-moments-ui-test", "-moments-photo-count", String(count), "-azurefish.locale.identifier", language, "-azurefish.appearance.preference", "light"]
            app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
            let photo = app.buttons["moments.photo.00000000-0000-0000-0000-000000000002.\(selected)"]
            XCTAssertTrue(photo.waitForExistence(timeout: 5))
            for _ in 0..<5 where photo.frame.midY > app.windows.firstMatch.frame.maxY - 80 { app.swipeUp() }
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let pager = app.collectionViews["moments.photo.pager"], position = app.staticTexts["moments.photo.position"]
            XCTAssertTrue(pager.waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["moments.preview.image.\(selected)"].waitForExistence(timeout: 5))
            let initial = position.label
            pager.swipeLeft()
            if count == 1 { XCTAssertEqual(position.label, initial) }
            else {
                XCTAssertTrue(app.images["moments.preview.image.3"].waitForExistence(timeout: 5))
                XCTAssertNotEqual(position.label, initial)
                let last = position.label; pager.swipeLeft(); XCTAssertEqual(position.label, last)
                pager.swipeRight(); XCTAssertEqual(position.label, initial)
            }
            app.buttons["moments.photo.close"].tap(); XCTAssertFalse(pager.exists)
            app.terminate()
        }
    }
    @MainActor func testArabicLargeTextFeed() {
        let app = XCUIApplication(); app.launchArguments = ["-moments-ui-test", "-azurefish.locale.identifier", "ar", "-azurefish.appearance.preference", "dark", "-AppleLanguages", "(ar)", "-AppleLocale", "ar", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
        XCTAssertTrue(app.collectionViews["moments.list"].waitForExistence(timeout: 5))
        app.swipeUp()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Moments Arabic large text"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCTAssertTrue(app.buttons["moments.like.00000000-0000-0000-0000-000000000002"].exists)
    }
    @MainActor func testSingleAndFourImageLayouts() {
        for count in [1, 4] {
            let app = XCUIApplication()
            app.launchArguments = ["-moments-ui-test", "-moments-photo-count", String(count), "-azurefish.locale.identifier", "en", "-azurefish.appearance.preference", "light"]
            app.launch(); XCTAssertTrue(app.cells["moments.entry"].waitForExistence(timeout: 10)); app.cells["moments.entry"].tap()
            XCTAssertTrue(app.navigationBars["Moments"].waitForExistence(timeout: 5))
            let prefix = "moments.photo.00000000-0000-0000-0000-000000000002."
            let first = app.buttons[prefix + "0"]
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            for _ in 0..<5 where first.frame.midY > app.windows.firstMatch.frame.maxY - 80 { app.swipeUp() }
            XCTAssertLessThanOrEqual(first.frame.width, 280)
            if count == 1 {
                XCTAssertEqual(first.frame.width / first.frame.height, 4 / 3, accuracy: 0.02)
                XCTAssertFalse(app.buttons[prefix + "1"].exists)
            } else {
                let second = app.buttons[prefix + "1"].frame, third = app.buttons[prefix + "2"].frame, fourth = app.buttons[prefix + "3"].frame
                XCTAssertEqual(first.frame.minY, second.minY, accuracy: 1)
                XCTAssertEqual(third.minY, fourth.minY, accuracy: 1)
                XCTAssertGreaterThan(third.minY, first.frame.maxY)
                XCTAssertEqual(first.frame.minX, third.minX, accuracy: 1)
                XCTAssertEqual(second.minX, fourth.minX, accuracy: 1)
                XCTAssertLessThanOrEqual(first.frame.union(second).width, 320)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Moments \(count) image layout"; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
    }
}
