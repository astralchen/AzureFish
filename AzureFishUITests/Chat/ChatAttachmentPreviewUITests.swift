import OSLog
import XCTest
import UIKit

private let logger = Logger(subsystem: "Demo.UITests", category: "ChatAttachmentPreviewUITests")

final class ChatAttachmentPreviewUITests: XCTestCase {
    override func setUpWithError() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Attachment preview requires iOS 26") }
        continueAfterFailure = false
    }
    @MainActor private func chat(fixture: String, locale: String = "zh-Hans", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-imessage-save-fixture", fixture, "-azurefish.locale.identifier", locale] + extra
        app.launchArguments += ["-chat-ui-test-root"]
        app.launch()
        let route = app.cells["demo.imessage.title"]
        if extra.contains("-UIPreferredContentSizeCategoryName") {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText("iMessage\n")
        } else {
            for _ in 0..<8 where !route.exists { app.collectionViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        route.tap()
        XCTAssertTrue(app.textViews["imessage.composer.text"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String, screenshot: XCUIScreenshot? = nil) {
        let attachment = XCTAttachment(screenshot: screenshot ?? app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// 采样屏幕中央主图区域，显隐控件前后应保留同一画面，避免仅检查 AX 漏掉黑屏。
    @MainActor private func mediaSample(_ screenshot: XCUIScreenshot) -> [UInt8] {
        let captured = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: captured.size, format: format).image { _ in
            captured.draw(in: CGRect(origin: .zero, size: captured.size))
        }
        guard let source = normalized.cgImage,
              let image = source.cropping(to: CGRect(x: CGFloat(source.width) * 0.2,
                  y: CGFloat(source.height) * 0.45, width: CGFloat(source.width) * 0.6,
                  height: CGFloat(source.height) * 0.1)) else {
            XCTFail("无法采样主图截图")
            return []
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 32 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 64, height: 32,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        return bytes.enumerated().compactMap { $0.offset % 4 == 3 ? nil : $0.element }
    }
    @MainActor private func openMedia(_ app: XCUIApplication) {
        let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
        XCTAssertTrue(media.waitForExistence(timeout: 10))
        media.tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
    }
    /// 除 xcresult 附件外保留独立截图，便于测试归档服务异常时仍能检查真实画面。
    @MainActor private func captureLivePhoto(_ app: XCUIApplication, _ name: String, screenshot: XCUIScreenshot? = nil) {
        let screenshot = screenshot ?? XCUIScreen.main.screenshot()
        let capturedImage = screenshot.image
        let attachment = XCTAttachment(image: capturedImage)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("png")
        do { try XCTUnwrap(capturedImage.pngData()).write(to: url) }
        catch { XCTFail("保存实况截图失败：\(error)") }
    }

    /// 单张实况经过草稿、发送和模拟回复后，消息仍可识别实况并打开原预览。
    @MainActor func testLivePhotoMessageBadges() {
        let app = chat(fixture: "resources-live-single", extra: ["-imessage-preview-draft"])
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 15))
        app.buttons["imessage.composer.send"].tap()
        let messages = app.descendants(matching: .any).matching(identifier: "imessage.media.message")
        let replied = NSPredicate { _, _ in messages.count == 2 }
        expectation(for: replied, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        for message in messages.allElementsBoundByIndex {
            XCTAssertTrue(message.label.contains("实况照片"), message.label)
        }
        captureLivePhoto(app, "实况照片-收发消息-iPhone16Pro")
        messages.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["imessage.preview.live"].waitForExistence(timeout: 10))
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(messages.element(boundBy: 1).waitForExistence(timeout: 5))
    }

    /// 从草稿进入实况预览，验证小屏菜单、沉浸、逐项开关、发送及重新打开。
    @MainActor func testLivePhotoBadgeMenuAndDraftToMessage() {
        let app = chat(fixture: "resources-live", extra: ["-imessage-preview-draft"])
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 15))
        thumbnail.tap()
        // 草稿条自动滚到最后选中项；明确切到资源组中的第一张实况。
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
        app.cells["imessage.preview.thumbnail.0"].tap()
        let badge = app.buttons["imessage.preview.live"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.value as? String, "实况")
        XCTAssertGreaterThanOrEqual(badge.frame.minX, 16)
        XCTAssertLessThanOrEqual(badge.frame.maxX, app.frame.width - 16)
        captureLivePhoto(app, "实况-iPhoneSE-开启")
        badge.tap()
        captureLivePhoto(app, "实况-iPhoneSE-菜单")
        app.buttons["关闭实况"].tap()
        XCTAssertEqual(badge.value as? String, "实况已关闭")
        captureLivePhoto(app, "实况-iPhoneSE-关闭")
        app.cells["imessage.preview.thumbnail.1"].tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
        app.cells["imessage.preview.thumbnail.2"].tap()
        XCTAssertFalse(badge.exists, "GIF 不能标成实况")
        app.cells["imessage.preview.thumbnail.3"].tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertEqual(badge.value as? String, "实况")
        app.cells["imessage.preview.thumbnail.0"].tap()
        // 切页动画完成后才提交当前项目，徽标在相邻实况页上也一直存在。
        expectation(for: NSPredicate(format: "value == %@", "实况已关闭"), evaluatedWith: badge)
        waitForExpectations(timeout: 5)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
        captureLivePhoto(app, "实况-iPhoneSE-沉浸")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.buttons["imessage.media.preview.close"].tap()
        app.buttons["imessage.composer.send"].tap()
        openMedia(app)
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertEqual(badge.value as? String, "实况")
        // 保留长按区间供模拟器录屏检查实际运动；松手后回到静态照片。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3)
        XCTAssertFalse(app.staticTexts["imessage.preview.message"].exists)
        captureLivePhoto(app, "实况-iPhoneSE-发送后播放")
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 真机像素必须持续变化；菜单切换、缩放、翻页和重新打开不改变照片身份。
    @MainActor func testLivePhotoLoopAndBouncePreview() {
        let app = chat(fixture: "resources-live")
        openMedia(app)
        app.cells["imessage.preview.thumbnail.0"].tap()
        let badge = app.buttons["imessage.preview.live"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        func assertMoving() {
            let initial = mediaSample(XCUIScreen.main.screenshot())
            let moving = NSPredicate { _, _ in
                let next = self.mediaSample(XCUIScreen.main.screenshot())
                return zip(initial, next).filter { abs(Int($0) - Int($1)) > 12 }.count > initial.count / 100
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moving, object: nil)], timeout: 15), .completed)
        }
        badge.tap()
        captureLivePhoto(app, "实况-四项菜单-iPhoneSE")
        for title in ["循环播放", "来回播放"] {
            if title == "来回播放" { badge.tap() }
            app.buttons[title].tap()
            XCTAssertEqual(badge.value as? String, title)
            assertMoving()
            XCTAssertFalse(app.sliders["imessage.preview.progress"].exists)
            captureLivePhoto(app, "实况-" + title + "-iPhoneSE")
        }
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        assertMoving()
        center.doubleTap()
        center.tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5))
        assertMoving()
        center.tap()
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        app.cells["imessage.preview.thumbnail.3"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "实况"), object: badge)], timeout: 5), .completed)
        app.cells["imessage.preview.thumbnail.0"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "来回播放"), object: badge)], timeout: 5), .completed)
        assertMoving()
        badge.tap()
        app.buttons["关闭实况"].tap()
        XCTAssertEqual(badge.value as? String, "实况已关闭")
        let still = mediaSample(XCUIScreen.main.screenshot())
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(still, mediaSample(XCUIScreen.main.screenshot()))
        app.buttons["imessage.media.preview.close"].tap()
        openMedia(app)
        XCTAssertEqual(badge.value as? String, "实况")
        app.buttons["imessage.media.preview.close"].tap()
    }

    @MainActor func testLivePhotoLandscapeRTLAndLargeText() {
        let app = chat(fixture: "resources-live", locale: "ar",
                       extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openMedia(app)
        let badge = app.buttons["imessage.preview.live"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(badge.frame.midX, app.frame.midX)
        badge.tap()
        app.buttons["ارتداد"].tap()
        XCTAssertEqual(badge.value as? String, "ارتداد")
        captureLivePhoto(app, "实况-RTL-大字号")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && badge.isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertGreaterThanOrEqual(badge.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(badge.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(badge.frame.minY, app.frame.minY)
        XCTAssertLessThanOrEqual(badge.frame.maxY, app.frame.maxY)
        captureLivePhoto(app, "实况-RTL-横屏")
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 无需长按，切到 GIF 后屏幕实际像素持续变化；沉浸显隐不应停止播放。
    @MainActor func testGIFPreviewAutoplaysWithoutPressing() {
        let app = chat(fixture: "resources-live")
        openMedia(app)
        app.cells["imessage.preview.thumbnail.2"].tap()
        XCTAssertTrue(app.buttons["imessage.preview.live"].waitForNonExistence(timeout: 5))
        func assertMoving() {
            let first = mediaSample(XCUIScreen.main.screenshot())
            XCTAssertFalse(first.isEmpty)
            var changed = false
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.17)
                let next = mediaSample(XCUIScreen.main.screenshot())
                if zip(first, next).filter({ abs(Int($0) - Int($1)) > 12 }).count > first.count / 100 {
                    changed = true
                    break
                }
            }
            XCTAssertTrue(changed, "GIF 必须直接播放，并输出不同的实际画面")
        }
        assertMoving()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForNonExistence(timeout: 5))
        assertMoving()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 5))
        app.cells["imessage.preview.thumbnail.1"].tap()
        app.cells["imessage.preview.thumbnail.2"].tap()
        assertMoving()
        captureLivePhoto(app, "GIF-iPhoneSE-直接播放")
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 经过系统选择器导入真实相册实况，输入栏和全屏预览都必须保持照片身份。
    @MainActor func testSystemLivePhotoSelectionKeepsPhotoDraft() throws {
        let app = chat(fixture: "none")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 15))
        let live = photos.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "实况", "Live Photo")).firstMatch
        guard live.exists else { throw XCTSkip("当前照片选择器可见范围内没有实况照片") }
        live.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        // 首次读取原始实况时由设备使用者选择相册授权范围。
        XCTAssertTrue(preview.waitForExistence(timeout: 120))
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "imessage.composer.media.", "视频")).count, 0)
        captureLivePhoto(app, "系统实况导入-输入栏")
        preview.tap()
        // 允许读取所选原始资源后，循环效果照片也应保留真正的实况配对。
        XCTAssertTrue(app.staticTexts["图片"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["imessage.preview.live"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.sliders["imessage.preview.progress"].exists)
        captureLivePhoto(app, "系统实况导入-播放前")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 3)
        XCTAssertFalse(app.staticTexts["imessage.preview.message"].exists)
        var restoredScreenshot: XCUIScreenshot?
        let coverRestored = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let screenshot = XCUIScreen.main.screenshot()
            let sample = mediaSample(screenshot)
            let restored = !sample.isEmpty && sample.filter { $0 > 24 }.count > sample.count / 4
            if restored { restoredScreenshot = screenshot }
            return restored
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [coverRestored], timeout: 5), .completed, "松手后必须恢复照片，不能黑屏")
        XCTAssertTrue(app.buttons["imessage.preview.live"].exists)
        captureLivePhoto(app, "系统实况导入-全屏照片预览", screenshot: restoredScreenshot)
        for title in ["循环播放", "来回播放"] {
            let badge = app.buttons["imessage.preview.live"]
            badge.tap()
            app.buttons[title].tap()
            XCTAssertEqual(badge.value as? String, title)
            let first = mediaSample(XCUIScreen.main.screenshot())
            let moving = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let next = self.mediaSample(XCUIScreen.main.screenshot())
                return zip(first, next).filter { abs(Int($0) - Int($1)) > 12 }.count > first.count / 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moving], timeout: 20), .completed)
            XCTAssertFalse(app.staticTexts["imessage.preview.message"].exists)
            captureLivePhoto(app, "系统实况导入-" + title)
        }
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 为真实视频的播放与跳转后播放提供无操作录屏区间；画面连续性需另行检查录屏。
    /// 两段等待期间不查询 AX、不截图、不拖动进度，让画面自行连续输出。
    @MainActor func testSentVideoUninterruptedPlaybackForRecording() {
        let app = chat(fixture: "resources-video", extra: ["-imessage-preview-draft"])
        let send = app.buttons["imessage.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        send.tap()
        openMedia(app)
        let play = app.buttons["imessage.preview.play"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        logger.notice("VIDEO_UNTOUCHED_BEGIN \(Date().timeIntervalSince1970, privacy: .public)")
        Thread.sleep(forTimeInterval: 10)
        logger.notice("VIDEO_UNTOUCHED_END \(Date().timeIntervalSince1970, privacy: .public)")
        XCTAssertGreaterThanOrEqual(playbackSeconds(app.sliders["imessage.preview.progress"]), 9)
        app.sliders["imessage.preview.progress"].adjust(toNormalizedSliderPosition: 0.25)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 10), .completed)
        logger.notice("VIDEO_AFTER_SEEK_BEGIN \(Date().timeIntervalSince1970, privacy: .public)")
        Thread.sleep(forTimeInterval: 6)
        logger.notice("VIDEO_AFTER_SEEK_END \(Date().timeIntervalSince1970, privacy: .public)")
        XCTAssertGreaterThanOrEqual(playbackSeconds(app.sliders["imessage.preview.progress"]), 10)
        play.tap()
        capture(app, "视频-无操作播放与拖动后恢复")
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 滚动和缩略图切换自动播放，沉浸状态保持隐藏，并为连续画面检查提供无操作区间。
    @MainActor func testPagingToVideoAutoplaysWithoutShowingHiddenControls() {
        let app = chat(fixture: "resources-video")
        openMedia(app)
        let play = app.buttons["imessage.preview.play"]
        let initiallyPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [initiallyPlaying], timeout: 10), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.1"].isSelected)
        logger.notice("VIDEO_AUTOPLAY_BEGIN \(Date().timeIntervalSince1970, privacy: .public)")
        Thread.sleep(forTimeInterval: 8)
        logger.notice("VIDEO_AUTOPLAY_END \(Date().timeIntervalSince1970, privacy: .public)")
        XCTAssertGreaterThanOrEqual(playbackSeconds(app.sliders["imessage.preview.progress"]), 7)
        play.tap()
        app.cells["imessage.preview.thumbnail.2"].tap()
        let nextPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [nextPlaying], timeout: 10), .completed)
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: app.cells["imessage.preview.thumbnail.2"])
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["imessage.media.preview.close"]
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(close.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let restoredPlaying = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [restoredPlaying], timeout: 5), .completed)
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.3"].isSelected)
        capture(app, "视频-翻页自动播放与沉浸恢复")
        app.buttons["imessage.media.preview.close"].tap()
    }

    /// 检查发送后各视频在不同播放时刻的主画面变化。
    @MainActor func testSentVideoActuallyRendersMovingFrames() {
        let app = chat(fixture: "resources-video", extra: ["-imessage-preview-draft"])
        let send = app.buttons["imessage.composer.send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        send.tap()
        openMedia(app)
        for index in 0..<6 {
            if index > 0 {
                let target = app.cells["imessage.preview.thumbnail.\(index)"]
                XCTAssertTrue(target.waitForExistence(timeout: 5))
                target.tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: target)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
            }
            let play = app.buttons["imessage.preview.play"]
            XCTAssertTrue(play.waitForExistence(timeout: 5))
            let progress = app.sliders["imessage.preview.progress"]
            let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
            XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
            let started = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                playbackSeconds(progress) >= 3
            }, object: progress)
            XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
            let firstFrame = app.screenshot()
            capture(app, "发送视频-\(index + 1)-播放三秒", screenshot: firstFrame)
            let initialTime = playbackSeconds(progress)
            let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                playbackSeconds(progress) >= initialTime + 3
            }, object: progress)
            XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed)
            let laterFrame = app.screenshot()
            capture(app, "发送视频-\(index + 1)-后续三秒", screenshot: laterFrame)
            let before = mediaSample(firstFrame), after = mediaSample(laterFrame)
            let difference = zip(before, after).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            XCTAssertGreaterThan(difference / Double(max(1, before.count)), 2,
                "播放时间已前进三秒，但主视频区域仍是同一张画面")
        }
        app.buttons["imessage.media.preview.close"].tap()
    }
    /// 从辅助功能时间文案读取已播放秒数，等待媒体时钟而非固定休眠。
    @MainActor private func playbackSeconds(_ slider: XCUIElement) -> Int {
        let time = (slider.value as? String ?? "").components(separatedBy: "/")[0]
            .trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard time.count == 2 else { return 0 }
        return time[0] * 60 + time[1]
    }
    /// 从工程资源走真实导入和预览入口，验证图片、视频封面与 PDF 可用。
    @MainActor func testBundledResourcesPreview() {
        for fixture in ["resources", "resources-heic", "resources-video", "resources-pdf"] {
            let app = chat(fixture: fixture)
            if fixture == "resources-pdf" {
                let card = app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 30))
                card.tap()
                XCTAssertTrue(app.otherElements["imessage.preview.pdf"].waitForExistence(timeout: 10))
            } else if fixture == "resources-heic" {
                let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
                XCTAssertTrue(media.waitForExistence(timeout: 30))
                openMedia(app)
                XCTAssertFalse(app.cells["imessage.preview.thumbnail.1"].exists)
            } else {
                let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
                XCTAssertTrue(media.waitForExistence(timeout: 30))
                openMedia(app)
                let target = app.cells["imessage.preview.thumbnail.4"]
                XCTAssertTrue(target.waitForExistence(timeout: 5))
                target.tap()
                let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: target)
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
                XCTAssertEqual(target.frame.width, 30, accuracy: 0.5)
                XCTAssertEqual(target.frame.midX, app.frame.midX, accuracy: 0.5)
                if fixture == "resources-video" {
                    let play = app.buttons["imessage.preview.play"]
                    XCTAssertTrue(play.waitForExistence(timeout: 10))
                    let slider = app.sliders["imessage.preview.progress"]
                    XCTAssertTrue(slider.waitForExistence(timeout: 5))
                    slider.adjust(toNormalizedSliderPosition: 0.5)
                    let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
                    XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
                } else {
                    let beforeScreenshot = app.screenshot()
                    capture(app, "真实资源-隐藏前", screenshot: beforeScreenshot)
                    let before = mediaSample(beforeScreenshot)
                    XCTAssertGreaterThan(before.reduce(0.0) { $0 + Double($1) } / Double(max(1, before.count)), 5)
                    let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    center.tap()
                    XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForNonExistence(timeout: 5))
                    let hiddenScreenshot = app.screenshot()
                    let hidden = mediaSample(hiddenScreenshot)
                    XCTAssertEqual(before.count, hidden.count)
                    let difference = zip(before, hidden).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    XCTAssertLessThan(difference / Double(max(1, before.count)), 3,
                        "沉浸隐藏前后主图像素应保持一致，不能被全屏玻璃合成层遮蔽")
                    capture(app, "真实资源-沉浸隐藏", screenshot: hiddenScreenshot)
                    center.tap()
                    XCTAssertTrue(target.waitForExistence(timeout: 5))
                    XCTAssertTrue(target.isSelected)
                    let restoredScreenshot = app.screenshot()
                    let restored = mediaSample(restoredScreenshot)
                    let restoredDifference = zip(before, restored).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    XCTAssertLessThan(restoredDifference / Double(max(1, before.count)), 3,
                        "恢复控件后主图不能跟随布局宿主执行出现／消失动画")
                    capture(app, "真实资源-恢复控件", screenshot: restoredScreenshot)
                }
            }
            capture(app, "真实资源-\(fixture)")
            app.buttons["imessage.media.preview.close"].tap()
            app.terminate()
        }
    }
    /// 截图规格、点击、真实拖动和沉浸恢复共用用户实际入口。
    @MainActor func testThumbnailFilmstripGeometryScrubbingAndImmersion() {
        let app = chat(fixture: "stack20")
        openMedia(app)
        let first = app.cells["imessage.preview.thumbnail.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.width, 30, accuracy: 0.5)
        XCTAssertEqual(first.frame.midX, app.frame.midX, accuracy: 0.5)
        let second = app.cells["imessage.preview.thumbnail.1"]
        let third = app.cells["imessage.preview.thumbnail.2"]
        XCTAssertEqual(second.frame.width, 20, accuracy: 0.5)
        XCTAssertEqual(second.frame.minX - first.frame.maxX, 13, accuracy: 0.5)
        XCTAssertEqual(third.frame.minX - second.frame.maxX, 3, accuracy: 0.5)
        capture(app, "胶片条-首项居中-透明背景")
        let fifth = app.cells["imessage.preview.thumbnail.4"]
        fifth.tap()
        let selected = NSPredicate(format: "selected == true")
        expectation(for: selected, evaluatedWith: fifth)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(fifth.frame.midX, app.frame.midX, accuracy: 0.5)
        capture(app, "胶片条-中间项居中")
        let stripY = fifth.frame.midY
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.8, dy: stripY))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.2, dy: stripY))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let current = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "imessage.preview.thumbnail.")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertNotEqual(current.identifier, "imessage.preview.thumbnail.4")
        XCTAssertEqual(current.frame.midX, app.frame.midX, accuracy: 0.5)
        let previousIdentifier = current.identifier
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        let close = app.buttons["imessage.media.preview.close"]
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        capture(app, "胶片条-沉浸隐藏")
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        left.press(forDuration: 0.1, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertFalse(close.exists)
        center.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let restored = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND selected == true", "imessage.preview.thumbnail.")).firstMatch
        XCTAssertTrue(restored.exists)
        XCTAssertNotEqual(restored.identifier, previousIdentifier)
        XCTAssertEqual(restored.frame.midX, app.frame.midX, accuracy: 0.5)
        capture(app, "胶片条-沉浸翻页后恢复")
    }

    @MainActor func testGroupNavigationCancelAndCompleteDismissal() {
        let app = chat(fixture: "stack20")
        openMedia(app)
        let title = app.otherElements["imessage.preview.title"]
        let back = app.buttons["imessage.media.preview.close"]
        let more = app.buttons["imessage.preview.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertEqual(title.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(back.frame.width, 44, accuracy: 1)
        XCTAssertEqual(more.frame.width, 44, accuracy: 1)
        XCTAssertLessThan(back.frame.maxX, title.frame.minX)
        XCTAssertLessThan(title.frame.maxX, more.frame.minX)
        let position = app.staticTexts["imessage.preview.position"]
        XCTAssertTrue(position.label.contains("20"))
        let firstPosition = position.label
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.45))
        let short = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(position.label, firstPosition)
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.1"].isSelected)
        let pages = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.preview.page.")).allElementsBoundByIndex
        let centered = pages.min { abs($0.frame.midX - app.frame.midX) < abs($1.frame.midX - app.frame.midX) }
        XCTAssertNotNil(centered)
        XCTAssertEqual(centered?.frame.minX ?? -100, app.frame.minX, accuracy: 1)
        XCTAssertEqual(centered?.frame.width ?? 0, app.frame.width, accuracy: 1)
        capture(app, "自定义分页-快滑准确停第二页")
        app.cells["imessage.preview.thumbnail.0"].tap()
        end.press(forDuration: 0.05, thenDragTo: start, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(position.label, firstPosition)
        capture(app, "居中玻璃顶部-首项")
        more.tap()
        app.buttons["下一个附件"].tap()
        XCTAssertTrue(position.label.contains("2"))
        app.cells["imessage.preview.thumbnail.1"].tap()
        XCTAssertTrue(position.label.contains("2"))
        capture(app, "玻璃预览-第二项")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(position.label.contains("2"))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(position.label.contains("2"))
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        origin.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)), withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].exists)
        capture(app, "下拉取消-恢复")
        origin.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForNonExistence(timeout: 5))
        openMedia(app)
        XCTAssertTrue(position.label.contains("2"))
        app.buttons["imessage.media.preview.close"].tap()
        capture(app, "收回到当前封面")
    }
    @MainActor func testMediaRowContainsStackBeforeAndAfterPreview() {
        let app = chat(fixture: "stack20")
        func checkGeometry() {
            let media = app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch
            let cell = app.cells.containing(.any, identifier: "imessage.media.message").firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(cell.frame.height, media.frame.height)
            XCTAssertGreaterThanOrEqual(media.frame.minY, cell.frame.minY)
            XCTAssertLessThanOrEqual(media.frame.maxY, cell.frame.maxY)
        }
        checkGeometry()
        capture(app, "修复后-媒体行完整占高")
        openMedia(app)
        app.cells["imessage.preview.thumbnail.1"].tap()
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForNonExistence(timeout: 5))
        checkGeometry()
        capture(app, "修复后-预览返回媒体行")
    }

    @MainActor func testSingleImageZoomAndControls() {
        let app = chat(fixture: "photo")
        openMedia(app)
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.doubleTap()
        capture(app, "图片双击放大")
        center.doubleTap()
        center.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["imessage.media.preview.close"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        center.tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 3))
        app.buttons["imessage.media.preview.close"].tap()
    }
    @MainActor func testPDFAndAudioFileUseCustomPreview() {
        for fixture in ["document", "audio", "preview-text"] {
            let app = chat(fixture: fixture)
            let card = app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            card.tap()
            XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
            if fixture == "audio" {
                let play = app.buttons["imessage.preview.play"]
                XCTAssertTrue(play.exists)
                play.tap()
            } else if fixture == "preview-text" {
                let text = app.textViews["imessage.preview.text"]
                XCTAssertTrue(text.waitForExistence(timeout: 5))
                text.swipeUp(velocity: .slow)
                text.swipeDown(velocity: .slow)
                XCTAssertTrue(app.buttons["imessage.media.preview.close"].exists)
            } else {
                let pdf = app.otherElements["imessage.preview.pdf"]
                XCTAssertTrue(pdf.waitForExistence(timeout: 5))
                pdf.pinch(withScale: 2, velocity: 1)
                pdf.swipeUp(velocity: .slow)
                pdf.swipeDown(velocity: .slow)
                XCTAssertTrue(app.buttons["imessage.media.preview.close"].exists)
            }
            capture(app, "自定义文件-\(fixture)")
            app.buttons["imessage.media.preview.close"].tap()
            app.terminate()
        }
    }
    @MainActor func testRTLAndAccessibilitySize() {
        let app = chat(fixture: "stack2", locale: "ar", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openMedia(app)
        capture(app, "RTL-辅助功能最大字号")
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].isHittable)
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.1"].isHittable)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.1"].isSelected)
        app.buttons["imessage.media.preview.close"].tap()
    }
    /// 用真实触摸覆盖展开、拖动、松手收起；录屏用于检查中间形态及进度连续性。
    @MainActor func testVideoScrubberMorphAndRestore() {
        let app = chat(fixture: "resources-video")
        openMedia(app)
        let play = app.buttons["imessage.preview.play"]
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let slider = app.sliders["imessage.preview.progress"]
        let before = slider.frame
        capture(app, "播放条-普通形态")
        logger.notice("SCRUB_MORPH_BEGIN \(Date().timeIntervalSince1970, privacy: .public)")
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2)
        logger.notice("SCRUB_MORPH_END \(Date().timeIntervalSince1970, privacy: .public)")
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].isHittable)
        XCTAssertTrue(app.buttons["imessage.preview.mute"].isHittable)
        XCTAssertEqual(slider.frame.midY, before.midY, accuracy: 0.5)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        play.tap()
        slider.adjust(toNormalizedSliderPosition: 0.4)
        XCTAssertTrue(play.label.hasPrefix("播放"), "暂停状态下拖动，松手后应继续暂停")
        capture(app, "播放条-拖动后恢复")
        app.buttons["imessage.media.preview.close"].tap()
    }
    @MainActor func testVideoPlaysInlineAndSeeks() {
        let app = chat(fixture: "preview-video")
        openMedia(app)
        let play = app.buttons["imessage.preview.play"]
        XCTAssertTrue(play.exists)
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let slider = app.sliders["imessage.preview.progress"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "暂停"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 3), .completed, "Playback label after seek: \(play.label)")
        app.buttons["imessage.preview.mute"].tap()
        capture(app, "页内视频-进度与静音")
        app.buttons["imessage.media.preview.close"].tap()
    }
    @MainActor func testPhotoAndDocumentDraftReturnPreservesTextAndFocus() {
        for fixture in ["stack2", "preview-text"] {
            let app = chat(fixture: fixture, extra: ["-imessage-preview-draft"])
            let text = app.textViews["imessage.composer.text"]
            text.tap()
            text.typeText("Keep draft")
            if fixture == "stack2" {
                let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
                XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
                thumbnail.tap()
            } else {
                let card = app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch
                XCTAssertTrue(card.waitForExistence(timeout: 5))
                card.tap()
            }
            XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
            capture(app, "草稿预览-\(fixture)")
            app.buttons["imessage.media.preview.close"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue((text.value as? String)?.contains("Keep draft") == true)
            app.terminate()
        }
    }
    @MainActor func testQuickLookFallbackAndUnavailableFile() {
        let app = chat(fixture: "preview-rtf", locale: "en")
        app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["imessage.media.preview.close"].exists)
        capture(app, "QuickLook-兼容文件")
        app.terminate()
        let missing = chat(fixture: "preview-unavailable")
        missing.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch.tap()
        XCTAssertTrue(missing.staticTexts["imessage.preview.message"].waitForExistence(timeout: 10))
        capture(missing, "文件不可用-错误状态")
        missing.buttons["imessage.media.preview.close"].tap()
    }

    @MainActor func testPhotoSheetPullDownPreservesDraftAndReopens() {
        let app = chat(fixture: "stack2", extra: ["-imessage-preview-draft"])
        let composer = app.otherElements["imessage.composer"]
        let restingBottom = composer.frame.maxY
        let text = app.textViews["imessage.composer.text"]
        text.tap()
        text.typeText("Keep draft after dismissal")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let originalY = grabber.frame.midY
        let originalComposerBottom = composer.frame.maxY
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        let thumbnailID = thumbnail.identifier
        capture(app, "下拉收起-展开与草稿")

        // 小幅慢拖后停留，系统应取消关闭并恢复原位。
        let start = grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(.init(dx: 0, dy: 20)),
                    withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(grabber.exists)
        XCTAssertEqual(grabber.frame.midY, originalY, accuracy: 2)
        XCTAssertEqual(composer.frame.maxY, originalComposerBottom, accuracy: 2)
        capture(app, "下拉收起-短拖回弹")

        let bottom = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.98))
        grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(grabber.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 2)
        XCTAssertEqual(text.value as? String, "Keep draft after dismissal")
        XCTAssertTrue(app.buttons[thumbnailID].exists)
        capture(app, "下拉收起-保留草稿与底部安全区")

        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[thumbnailID].exists)
        XCTAssertEqual(grabber.frame.midY, originalY, accuracy: 2)
        capture(app, "下拉收起-重新打开")
        // 展开到大档，慢拖回原来的小档，再继续拖动关闭。
        grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.15)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(grabber.frame.midY, originalY - 100)
        capture(app, "下拉收起-大档")
        grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: .zero)
                .withOffset(.init(dx: app.frame.midX, dy: originalY)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(grabber.exists)
        XCTAssertEqual(grabber.frame.midY, originalY, accuracy: 2)
        grabber.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(grabber.waitForNonExistence(timeout: 5))
        XCTAssertEqual(composer.frame.maxY, restingBottom, accuracy: 2)
        XCTAssertTrue(app.buttons[thumbnailID].exists)

        // 再次打开后切换回文字键盘，验证主动关闭仍使用相同的收尾路径。
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(grabber.waitForNonExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "Keep draft after dismissal")
        capture(app, "下拉收起-重开后切键盘")
    }

    @MainActor func testPhotoSheetRemainsAtItsDetent() {
        let app = chat(fixture: "stack2", extra: ["-imessage-preview-draft"])
        let text = app.textViews["imessage.composer.text"]
        text.tap()
        text.typeText("Keep panel")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let before = grabber.frame.midY
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        // 系统照片扩展展示时 AX 可能把未被遮挡的输入栏标记为不可点击。
        // 先确认缩略图完整处于面板上方，再按可见屏幕坐标点击。
        XCTAssertLessThan(thumbnail.frame.maxY, grabber.frame.minY)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(.init(dx: thumbnail.frame.midX, dy: thumbnail.frame.midY)).tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
        capture(app, "照片面板上打开预览")
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        XCTAssertEqual(grabber.frame.midY, before, accuracy: 1)
        XCTAssertTrue((text.value as? String)?.contains("Keep panel") == true)
        capture(app, "预览返回-照片面板原档位")
    }

    /// 发送媒体和正文后，照片面板继续占据原档位，输入栏仅收起已发送的草稿。
    @MainActor func testSendingKeepsPhotoSheetOpen() {
        let app = chat(fixture: "stack2", extra: ["-imessage-preview-draft"])
        let text = app.textViews["imessage.composer.text"]
        text.tap()
        text.typeText("Keep selecting")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let before = grabber.frame.midY
        capture(app, "连续选图-发送前")
        app.buttons["imessage.composer.send"].tap()
        let thumbnail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        XCTAssertTrue(thumbnail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(grabber.exists)
        XCTAssertEqual(grabber.frame.midY, before, accuracy: 1)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse((text.value as? String)?.contains("Keep selecting") == true)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "imessage.media.message").firstMatch.exists)
        capture(app, "连续选图-发送后保持面板")
        // 模拟器照片库包含系统样例；连续两次选择同一首格，验证发送会同步取消系统勾选。
        let firstPhoto = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: app.frame.width / 6, dy: before + 70)
        )
        for batch in 1...2 {
            firstPhoto.tap()
            XCTAssertTrue(thumbnail.waitForExistence(timeout: 10))
            let send = app.buttons["imessage.composer.send"]
            let ready = NSPredicate(format: "isEnabled == true")
            expectation(for: ready, evaluatedWith: send)
            waitForExpectations(timeout: 20)
            send.tap()
            XCTAssertTrue(thumbnail.waitForNonExistence(timeout: 5))
            XCTAssertTrue(grabber.exists)
            XCTAssertEqual(grabber.frame.midY, before, accuracy: 1)
            capture(app, "连续选图-第\(batch)批后")
        }
    }

    /// 输入栏使用真实的实况、静态图和 GIF 混排，角标只属于实况照片。
    @MainActor func testComposerLivePhotoBadgesExcludeGIFAndStillImages() {
        let app = chat(fixture: "resources-live", extra: ["-imessage-preview-draft"])
        let previews = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview."))
        XCTAssertTrue(previews.firstMatch.waitForExistence(timeout: 10))
        let strip = app.otherElements["imessage.composer.mediaStrip"]
        XCTAssertTrue(strip.exists)
        // 初始展示队尾的 GIF 和实况照片，再滚到队首检查实况与普通图片。
        capture(app, "输入栏角标-GIF与实况")
        strip.swipeRight()
        capture(app, "输入栏角标-实况与普通图片")
        let badges = app.images.matching(identifier: "imessage.composer.media.livePhotoBadge")
        XCTAssertTrue(badges.firstMatch.exists)
    }

    /// 真实资源混排与键盘显示状态下，删除到空的高度变化及 RTL 外观。
    @MainActor func testMediaDraftQuickLayoutAndCollapse() {
        for locale in ["zh-Hans", "ar"] {
            let app = chat(fixture: "resources-draft", locale: locale, extra: ["-imessage-preview-draft"])
            let send = app.buttons["imessage.composer.send"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
            waitForExpectations(timeout: 20)
            let text = app.textViews["imessage.composer.text"]
            text.tap()
            text.typeText("Draft")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            capture(app, "草稿-QuickLayout-键盘-\(locale)")
            let composer = app.otherElements["imessage.composer"]
            let before = composer.frame.height
            let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.remove."))
            for _ in 0..<3 {
                let visible = remove.allElementsBoundByIndex.first(where: \.isHittable)
                XCTAssertNotNil(visible)
                visible?.tap()
            }
            XCTAssertTrue(remove.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertLessThan(composer.frame.height, before - 100)
            XCTAssertTrue(app.keyboards.firstMatch.exists)
            capture(app, "草稿-清空后-\(locale)")
            app.terminate()
        }
    }

    /// 从键盘中的空输入切到真实录音、预览，再取消回文本。
    @MainActor func testKeyboardToAudioPanelTransition() {
        let app = chat(fixture: "empty")
        let text = app.textViews["imessage.composer.text"]
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let composer = app.otherElements["imessage.composer"]
        let original = composer.frame
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["音频"].tap()
        let stop = app.buttons["imessage.composer.recording.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertEqual(composer.frame.maxY, original.maxY, accuracy: 1)
        XCTAssertGreaterThan(composer.frame.height, original.height)
        capture(app, "键盘-切换录音")
        stop.tap()
        let cancel = app.buttons["imessage.composer.audio.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, "键盘-录音预览")
        cancel.tap()
        XCTAssertTrue(app.buttons["imessage.composer.attachment"].waitForExistence(timeout: 5))
        XCTAssertEqual(composer.frame.height, original.height, accuracy: 1)
        XCTAssertEqual(composer.frame.maxY, original.maxY, accuracy: 1)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, "键盘-取消录音恢复文本")
    }

    /// 键盘上方的文本增高、删除回缩及发送清空均保持输入栏底边。
    @MainActor func testComposerTextHeightChangesWithKeyboard() {
        let app = chat(fixture: "empty")
        let text = app.textViews["imessage.composer.text"]
        text.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        text.typeText("One")
        let singleLineHeight = text.frame.height
        let bottom = text.frame.maxY
        let extraLines = "\nTwo\nThree\nFour"
        text.typeText(extraLines)
        XCTAssertGreaterThan(text.frame.height, singleLineHeight + 30)
        XCTAssertEqual(text.frame.maxY, bottom, accuracy: 1)
        capture(app, "文字高度-输入四行")
        text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: extraLines.count))
        let collapsed = NSPredicate { _, _ in abs(text.frame.height - singleLineHeight) < 1 }
        expectation(for: collapsed, evaluatedWith: text)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(text.value as? String, "One")
        XCTAssertEqual(text.frame.height, singleLineHeight, accuracy: 1)
        XCTAssertEqual(text.frame.maxY, bottom, accuracy: 1)
        text.typeText(extraLines)
        app.buttons["imessage.composer.send"].tap()
        expectation(for: collapsed, evaluatedWith: text)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(text.value as? String, "")
        XCTAssertEqual(text.frame.height, singleLineHeight, accuracy: 1)
        XCTAssertEqual(text.frame.maxY, bottom, accuracy: 1)
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        capture(app, "文字高度-发送后收起")
    }

    /// 从系统照片面板真实连续选图，覆盖首次展开、追加与清空。
    @MainActor func testMediaDraftSelectionAnimationFromPhotoSheet() {
        let app = chat(fixture: "empty")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let panelY = grabber.frame.midY
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview."))
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.remove."))
        let send = app.buttons["imessage.composer.send"]
        // Photos 扩展的 AX frame 是面板内坐标；先从真实宿主 frame 映射到屏幕。
        // 不假设列数，系统可按设备和版本显示三列或五列。
        let photos = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "照片"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 5))
        let sheet = app.otherElements.allElementsBoundByIndex.first {
            let frame = $0.frame
            return frame.minY > grabber.frame.minY && frame.minY < grabber.frame.maxY
                && frame.width < app.frame.width && frame.width > app.frame.width * 0.8 && frame.height > 200
        }
        XCTAssertNotNil(sheet)
        guard let sheet else { return }
        // 新安装的系统选择器会先显示隐私说明；关闭说明后才可点击背后的照片。
        if app.textViews["私密访问照片"].exists {
            let confirmation = app.buttons["好"]
            XCTAssertTrue(confirmation.exists)
            let frame = confirmation.frame
            let scale = sheet.frame.width / app.frame.width
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let point = sheet.frame.contains(center) ? center : CGPoint(
                x: sheet.frame.minX + center.x * scale,
                y: sheet.frame.minY + center.y * scale
            )
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(app.textViews["私密访问照片"].waitForNonExistence(timeout: 5))
        }
        for column in 0..<3 {
            let photo = photos.element(boundBy: column)
            XCTAssertTrue(photo.exists)
            let frame = photo.frame
            let scale = sheet.frame.width / app.frame.width
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let screenPoint = sheet.frame.contains(center) ? center : CGPoint(
                x: sheet.frame.minX + frame.midX * scale,
                y: sheet.frame.minY + frame.midY * scale
            )
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx: screenPoint.x, dy: screenPoint.y
            )).tap()
            XCTAssertTrue(preview.firstMatch.waitForExistence(timeout: 15))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: send)
            waitForExpectations(timeout: 20)
            XCTAssertEqual(grabber.frame.midY, panelY, accuracy: 1)
            capture(app, "草稿-系统选择第\(column + 1)张")
        }
        // PHPicker 的模态 AX 层级可能把下层可交互草稿报告为不可命中。
        // 使用输入栏内实际可见的中心点点击，并以真实打开预览作为验收。
        let composerFrame = app.otherElements["imessage.composer"].frame
        let source = preview.allElementsBoundByIndex.first {
            composerFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        XCTAssertNotNil(source)
        source?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForExistence(timeout: 10))
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            let visible = remove.allElementsBoundByIndex.first {
                composerFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }
            XCTAssertNotNil(visible)
            visible?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(remove.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(grabber.frame.midY, panelY, accuracy: 1)
        capture(app, "草稿-清空后保留照片面板")
    }

    @MainActor func testDeselectingLastPhotoInPickerCollapsesDraft() {
        let app = chat(fixture: "empty")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let panelY = grabber.frame.midY
        let photo = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "照片")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let frame = photo.frame
        let sheet = app.otherElements.allElementsBoundByIndex.first {
            let f = $0.frame
            return f.minY > grabber.frame.minY && f.minY < grabber.frame.maxY
                && f.width < app.frame.width && f.width > app.frame.width * 0.8 && f.height > 200
        }
        XCTAssertNotNil(sheet)
        guard let sheet else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let scale = sheet.frame.width / app.frame.width
        let point = sheet.frame.contains(center) ? center : CGPoint(
            x: sheet.frame.minX + frame.midX * scale, y: sheet.frame.minY + frame.midY * scale)
        let coordinate = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.remove.")).firstMatch
        // 同一网格项目再次点击取消勾选，不使用输入栏的删除按钮。
        let microphone = app.buttons["imessage.composer.dictation"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        let actionCenterY = microphone.frame.midY
        for _ in 0..<2 {
            coordinate.tap()
            XCTAssertTrue(preview.waitForExistence(timeout: 15))
            XCTAssertEqual(app.buttons["imessage.composer.send"].frame.midY, actionCenterY, accuracy: 1)
            coordinate.tap()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.buttons["imessage.composer.send"].exists)
            XCTAssertTrue(microphone.waitForExistence(timeout: 5))
            XCTAssertEqual(microphone.frame.midY, actionCenterY, accuracy: 1)
            XCTAssertEqual(grabber.frame.midY, panelY, accuracy: 1)
        }
        capture(app, "照片面板-反选最后一张后输入栏收起")
    }

    @MainActor func testLandscapeVideoDraftInitialSize() {
        let app = chat(fixture: "empty")
        app.buttons["imessage.composer.attachment"].tap()
        app.buttons["照片"].tap()
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 10))
        let videos = app.images.matching(identifier: "PXGGridLayout-Info")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "视频"))
        XCTAssertTrue(videos.firstMatch.waitForExistence(timeout: 10))
        let frame = videos.firstMatch.frame
        let sheet = app.otherElements.allElementsBoundByIndex.first {
            let f = $0.frame
            return f.minY > grabber.frame.minY && f.minY < grabber.frame.maxY
                && f.width < app.frame.width && f.width > app.frame.width * 0.8 && f.height > 200
        }
        XCTAssertNotNil(sheet)
        guard let sheet else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let scale = sheet.frame.width / app.frame.width
        let point = sheet.frame.contains(center) ? center : CGPoint(x: sheet.frame.minX + frame.midX * scale,
                                                                    y: sheet.frame.minY + frame.midY * scale)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.preview.")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(preview.frame.width, preview.frame.height)
        capture(app, "横向视频-首张选择")
    }

    /// 在真实系统开关开启时验证预览，并在任何退出路径恢复测试前的设置。
    @MainActor func testSystemReducedMotionAndTransparency() throws {
        // XCTest 的立即中止会绕过 Swift defer；保留失败记录并让设置恢复代码执行。
        continueAfterFailure = true
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        defer { settings.terminate() }

        /// 等待页面加载并双向查找；目标还须避开导航栏和底部搜索栏的遮挡。
        func reveal(_ element: XCUIElement) -> Bool {
            _ = element.waitForExistence(timeout: 3)
            for attempt in 0..<16 {
                if element.exists {
                    let middle = element.frame.midY
                    let top = settings.navigationBars.firstMatch.frame.maxY
                    let bottom = settings.frame.maxY - 160
                    if element.isHittable, middle > top, middle < bottom { return true }
                    if middle <= top { settings.swipeDown() } else { settings.swipeUp() }
                } else if attempt < 4 {
                    settings.swipeDown()
                } else {
                    settings.swipeUp()
                }
            }
            return false
        }

        /// 从设置根页面进入指定辅助功能页面，避免依赖上次运行留下的导航状态。
        func openPage(_ names: [String]) -> Bool {
            settings.activate()
            for _ in 0..<6 {
                let back = settings.navigationBars.buttons["BackButton"]
                guard back.exists else { break }
                back.tap()
            }
            let accessibility = settings.buttons["com.apple.settings.accessibility"]
            guard reveal(accessibility) else { return false }
            accessibility.tap()
            let page = settings.staticTexts.matching(NSPredicate(format: "label IN %@", names)).firstMatch
            guard reveal(page) else { return false }
            page.tap()
            return true
        }

        /// iOS 设置将整行和内部控件都暴露为 Switch；只有内部控件能可靠改变开关值。
        func toggle(_ names: [String]) -> XCUIElement {
            let row = settings.switches.matching(NSPredicate(format: "label IN %@", names)).firstMatch
            guard reveal(row) else { return row }
            let control = row.switches.firstMatch
            return control.exists ? control : row
        }

        /// 保留无法读取的状态，避免将未知状态误判为关闭。
        func state(_ control: XCUIElement) -> Bool? {
            if let number = control.value as? NSNumber { return number.boolValue }
            guard let value = control.value as? String else { return nil }
            return value == "1" ? true : (value == "0" ? false : nil)
        }

        /// 等待真实开关值改变，并将开启及恢复结果写入测试日志。
        func set(_ control: XCUIElement, to enabled: Bool, name: String) {
            guard let before = state(control) else {
                XCTFail("无法读取系统开关：\(name)")
                return
            }
            if before != enabled { control.tap() }
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                state(control) == enabled
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "系统开关未改变：\(name)")
            logger.notice("[AccessibilityEvidence] \(name, privacy: .public): \(before ? 1 : 0, privacy: .public) -> \(String(describing: state(control)), privacy: .public)")
        }

        let motionPage = ["Motion", "动态效果"]
        let motionNames = ["Reduce Motion", "减弱动态效果"]
        let displayPage = ["Display & Text Size", "显示与文字大小"]
        let transparencyNames = ["Reduce Transparency", "降低透明度"]
        guard openPage(motionPage) else { throw XCTSkip("Settings Motion entry unavailable") }
        let reduceMotion = toggle(motionNames)
        let motionWasOn = try XCTUnwrap(state(reduceMotion), "无法读取减弱动态效果初始状态")
        defer {
            if openPage(motionPage) {
                set(toggle(motionNames), to: motionWasOn, name: "恢复减弱动态效果")
            } else {
                XCTFail("无法返回动态效果页面恢复设置")
            }
        }
        set(reduceMotion, to: true, name: "开启减弱动态效果")
        capture(settings, "减弱动态效果已开启")

        guard openPage(displayPage) else {
            XCTFail("无法进入显示与文字大小页面")
            return
        }
        let transparency = toggle(transparencyNames)
        let transparencyWasOn = try XCTUnwrap(state(transparency), "无法读取降低透明度初始状态")
        defer {
            if openPage(displayPage) {
                set(toggle(transparencyNames), to: transparencyWasOn, name: "恢复降低透明度")
            } else {
                XCTFail("无法返回显示与文字大小页面恢复设置")
            }
        }
        set(transparency, to: true, name: "开启降低透明度")
        capture(settings, "降低透明度已开启")

        let app = chat(fixture: "stack2")
        openMedia(app)
        app.cells["imessage.preview.thumbnail.1"].tap()
        XCTAssertTrue(app.cells["imessage.preview.thumbnail.1"].isSelected)
        capture(app, "系统减少动态效果与降低透明度")
        app.buttons["imessage.media.preview.close"].tap()
        XCTAssertTrue(app.buttons["imessage.media.preview.close"].waitForNonExistence(timeout: 5))
        app.terminate()
        let draftApp = chat(fixture: "stack2", extra: ["-imessage-preview-draft"])
        let remove = draftApp.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "imessage.composer.media.remove."))
        XCTAssertTrue(remove.firstMatch.waitForExistence(timeout: 5))
        capture(draftApp, "草稿-减少动态效果")
        for _ in 0..<2 {
            let visible = remove.allElementsBoundByIndex.first(where: \.isHittable)
            XCTAssertNotNil(visible)
            visible?.tap()
        }
        XCTAssertTrue(remove.firstMatch.waitForNonExistence(timeout: 5))
        capture(draftApp, "草稿-减少动态效果-清空")
        draftApp.terminate()
    }

    @MainActor func testLargeTextDocumentClearsGlassHeader() {
        let app = chat(fixture: "preview-text", locale: "ar", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons.matching(identifier: "imessage.attachment.file.card").firstMatch.tap()
        let text = app.textViews["imessage.preview.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let header = app.otherElements["imessage.preview.title"]
        XCTAssertTrue(header.exists)
        XCTAssertGreaterThanOrEqual(text.frame.minY, header.frame.maxY)
        capture(app, "RTL-大字号文档首行不被遮挡")
        app.buttons["imessage.media.preview.close"].tap()
    }

}
