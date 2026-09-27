import XCTest

/// 账号界面与显式回环联调入口；不在测试中启用真实账号服务。
final class AccountFlowUITests: XCTestCase {
    @MainActor func testSecurityListActionsLanguagesAndThemes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-local-development"]
        app.launch()
        let entry = app.cells["account.design.security"]
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "Requires the existing fictional simulator session")
        func back() { app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "demo.language.menu")).firstMatch.tap() }
        func capture(_ name: String) {
            let item = XCTAttachment(screenshot: app.screenshot())
            item.name = name; item.lifetime = .keepAlways; add(item)
        }
        // 从现有选项页读取保存值，结束后恢复，不通过启动参数覆盖偏好。
        app.cells["account.design.settings"].tap()
        app.cells["account.design.language"].tap()
        let originalLanguage = ["system", "zh-Hans", "zh-Hant", "en-US", "ar"].first { app.cells["account.language." + $0].isSelected } ?? "system"
        back(); back(); entry.tap()
        let password = app.descendants(matching: .any).matching(identifier: "account.security.password").firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let actions = ["appleMethod", "changePassword", "signOutAll", "deleteAccount"]
        for action in actions {
            let row = app.cells["account.design." + action]
            XCTAssertTrue(row.isHittable)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            let title = row.label
            row.tap()
            XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
            XCTAssertTrue(app.alerts.staticTexts[title].exists)
            XCTAssertEqual(app.alerts.buttons.count, 1)
            if action == "deleteAccount" { capture("security-unavailable") }
            app.alerts.buttons.firstMatch.tap()
            XCTAssertTrue(app.tabBars.firstMatch.exists)
            XCTAssertTrue(password.exists)
        }
        for (identifier, nativeName) in [("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en", "English (United States)"), ("ar", "العربية"), ("en-restored", "English (United States)")] {
            app.buttons["demo.language.menu"].tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", nativeName + ",")).firstMatch.tap()
            XCTAssertTrue(password.exists)
            XCTAssertTrue(app.cells["account.design.deleteAccount"].isHittable)
            capture("security-" + identifier)
        }
        back()
        XCTAssertTrue(entry.exists)
        app.cells["account.design.settings"].tap()
        app.cells["account.design.appearance"].tap()
        let originalAppearance = ["system", "light", "dark"].first { app.cells["account.appearance." + $0].isSelected } ?? "system"
        for choice in ["light", "dark", "system"] {
            app.cells["account.appearance." + choice].tap()
            back(); back(); entry.tap()
            XCTAssertTrue(password.exists)
            capture("security-appearance-" + choice)
            back(); app.cells["account.design.settings"].tap(); app.cells["account.design.appearance"].tap()
        }
        app.cells["account.appearance." + originalAppearance].tap(); back()
        app.cells["account.design.language"].tap()
        app.cells["account.language." + originalLanguage].tap(); back(); back()
        XCTAssertTrue(entry.exists)
    }
    @MainActor func testSecurityLargeTextLayout() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "security.password"]
        app.launch()
        let list = app.collectionViews["account.security.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["account.security.methodsHelp"].exists)
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "security-large-top"; top.lifetime = .keepAlways; add(top)
        let deletion = app.cells["account.design.deleteAccount"]
        for _ in 0..<6 {
            if deletion.isHittable && deletion.frame.maxY <= list.frame.maxY - 8 { break }
            list.swipeUp()
        }
        XCTAssertTrue(deletion.isHittable)
        XCTAssertLessThanOrEqual(deletion.frame.maxY, list.frame.maxY)
        XCTAssertGreaterThanOrEqual(deletion.frame.height, 44)
        let bottom = XCTAttachment(screenshot: app.screenshot())
        bottom.name = "security-large-bottom"; bottom.lifetime = .keepAlways; add(bottom)
        deletion.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons.firstMatch.tap()
        XCTAssertTrue(deletion.isHittable)
    }
    @MainActor func testSettingsFromProfileKeepsTabBar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-local-development"]
        app.launch()
        let settings = app.cells["account.design.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "Requires the existing fictional simulator session")
        settings.tap()
        XCTAssertTrue(app.cells["account.design.appearance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        func capture(_ name: String) {
            let item = XCTAttachment(screenshot: app.screenshot())
            item.name = name; item.lifetime = .keepAlways; add(item)
        }
        capture("settings-profile-overview")
        app.cells["account.design.appearance"].tap()
        XCTAssertTrue(app.cells["account.appearance.system"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        capture("settings-profile-appearance")
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "demo.language.menu")).firstMatch.tap()
        app.cells["account.design.language"].tap()
        XCTAssertTrue(app.cells["account.language.system"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        capture("settings-profile-language")
    }
    @MainActor func testSettingsListPreferencesAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "settings"]
        app.launch()
        let appearance = app.cells["account.design.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        func capture(_ name: String) {
            let item = XCTAttachment(screenshot: app.screenshot())
            item.name = name; item.lifetime = .keepAlways; add(item)
        }
        func back() { app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "demo.language.menu")).firstMatch.tap() }
        func selected(_ id: String) {
            let row = app.cells[id]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.isSelected)
            XCTAssertEqual(app.cells.matching(NSPredicate(format: "selected == true")).count, 1)
        }
        appearance.tap()
        let originalAppearance = ["system", "light", "dark"].first { app.cells["account.appearance." + $0].isSelected } ?? "system"
        for choice in ["light", "dark", "system"] {
            app.cells["account.appearance." + choice].tap()
            selected("account.appearance." + choice)
            capture("settings-appearance-" + choice)
            if choice == "light" {
                back(); capture("settings-overview-light"); appearance.tap()
            }
        }
        app.cells["account.appearance.dark"].tap()
        back()
        capture("settings-overview-dark")
        app.cells["account.design.language"].tap()
        let originalLanguage = ["system", "zh-Hans", "zh-Hant", "en-US", "ar"].first { app.cells["account.language." + $0].isSelected } ?? "system"
        for identifier in ["zh-Hans", "zh-Hant", "en-US", "ar", "en-US", "system"] {
            let row = app.cells["account.language." + identifier]
            for _ in 0..<4 where !row.isHittable { app.collectionViews.firstMatch.swipeUp() }
            row.tap()
            selected("account.language." + identifier)
            if identifier != "system" { capture("settings-language-" + identifier) }
            if identifier == "ar" {
                back(); capture("settings-overview-ar"); app.cells["account.design.language"].tap()
            }
        }
        app.buttons["demo.language.menu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English (United States),")).firstMatch.tap()
        selected("account.language.en-US")
        back()
        XCTAssertEqual(app.cells["account.design.appearance"].value as? String, "Dark")
        XCTAssertEqual(app.cells["account.design.language"].value as? String, "English (United States)")
        capture("settings-overview-en")
        // 只为验证持久化重启一次，启动参数不覆盖偏好键。
        app.terminate(); app.launch()
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        XCTAssertEqual(appearance.value as? String, "Dark")
        XCTAssertEqual(app.cells["account.design.language"].value as? String, "English (United States)")
        appearance.tap(); selected("account.appearance.dark")
        app.cells["account.appearance." + originalAppearance].tap(); back()
        app.cells["account.design.language"].tap(); selected("account.language.en-US")
        app.cells["account.language." + originalLanguage].tap(); back()
    }
    @MainActor func testSettingsLargeTextLayout() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "settings"]
        app.launch()
        let appearance = app.cells["account.design.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 15))
        for key in ["account.design.appearance", "account.design.language"] {
            let cell = app.cells[key]
            XCTAssertGreaterThanOrEqual(cell.frame.height, 44)
            XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.maxX - 23)
        }
        XCTAssertTrue(app.staticTexts["account.design.appearanceHelp"].exists)
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "settings-large-overview"; overview.lifetime = .keepAlways; add(overview)
        let language = app.cells["account.design.language"]
        for _ in 0..<4 where !language.isHittable { app.collectionViews.firstMatch.swipeUp() }
        language.tap()
        let arabic = app.cells["account.language.ar"]
        XCTAssertTrue(arabic.waitForExistence(timeout: 5))
        for _ in 0..<6 where !arabic.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(arabic.isHittable)
        let options = XCTAttachment(screenshot: app.screenshot())
        options.name = "settings-large-language"; options.lifetime = .keepAlways; add(options)
    }
    @MainActor func testProfileListKitNavigationAndRTL() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-local-development", "-azurefish.locale.identifier", "zh-Hans"]
        app.launch()
        let edit = app.cells["account.design.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "Requires the existing fictional simulator session")
        XCTAssertTrue(app.collectionViews.firstMatch.exists)
        for key in ["account.design.editProfile", "account.design.security", "account.design.settings"] {
            let row = app.cells[key]
            XCTAssertTrue(row.isHittable)
            XCTAssertGreaterThanOrEqual(row.frame.height, 44)
            let arrow = row.images["chevron.forward"]
            XCTAssertTrue(arrow.exists)
            XCTAssertGreaterThan(arrow.frame.midX, row.frame.maxX - 32)
        }
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        capture("profile-listkit-zh-Hans")
        edit.tap()
        XCTAssertTrue(app.textViews["account.profile.bio"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.buttons["demo.language.menu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "العربية,")).firstMatch.tap()
        XCTAssertTrue(edit.isHittable)
        XCTAssertLessThan(edit.images["chevron.forward"].frame.midX, edit.frame.minX + 32)
        capture("profile-listkit-ar")
        app.buttons["demo.language.menu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "简体中文,")).firstMatch.tap()
        app.cells["account.design.signOut"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(edit.isHittable)
    }
    @MainActor func testLongProfileDraftExpandsAndKeepsKeyboardReachable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "edit", "-azurefish.locale.identifier", "en"]
        app.launch()
        let bio = app.textViews["account.profile.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 15))
        for _ in 0..<6 where !bio.isHittable { app.scrollViews.firstMatch.swipeUp() }
        bio.tap()
        let text = String(repeating: "Long profile text. ", count: 25)
        bio.typeText(text)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "profile-long-draft"; capture.lifetime = .keepAlways; add(capture)
        XCTAssertEqual(bio.value as? String, text)
        XCTAssertGreaterThan(bio.frame.height, 144)
        XCTAssertTrue(app.buttons["account.design.save"].isHittable)
    }
    @MainActor func testWelcomeFourLanguagesAndUnavailableApple() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "welcome", "-azurefish.locale.identifier", "en"]
        app.launch()
        for (locale, menuLabel, nativeName) in [("en", "Language", "English (United States)"), ("zh-Hans", "Language", "简体中文"), ("zh-Hant", "语言", "繁體中文"), ("ar", "語言", "العربية")] {
            let login = app.buttons["account.design.accountLogin"]
            XCTAssertTrue(login.waitForExistence(timeout: 15))
            if locale != "en" {
                app.buttons[menuLabel].tap()
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", nativeName + ",")).firstMatch.tap()
            }
            XCTAssertGreaterThanOrEqual(login.frame.height, 44)
            XCTAssertTrue(login.isHittable)
            let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "welcome-\(locale)"; attachment.lifetime = .keepAlways; add(attachment)
        }
        app.buttons["اللغة"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English (United States),")).firstMatch.tap()
        for choice in ["Light", "Dark", "System default"] {
            app.buttons["Appearance"].tap(); app.buttons[choice].tap()
            XCTAssertTrue(app.buttons["account.design.accountLogin"].isHittable)
            let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "welcome-appearance-" + choice; capture.lifetime = .keepAlways; add(capture)
        }
        app.buttons["account.design.appleLogin"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
    }
    @MainActor func testPasswordVisibilityAndInputSurvivesMenuLanguageChange() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-scenario", "login.empty", "-azurefish.locale.identifier", "en"]
        app.launch()
        let field = app.textFields["account.input.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap(); field.typeText("fictional_user")
        let password = app.secureTextFields["account.input.password"]
        password.tap(); password.typeText("Fictional-Password-123")
        app.buttons["Show password"].tap()
        XCTAssertEqual(app.textFields["account.input.password"].value as? String, "Fictional-Password-123")
        app.buttons["demo.language.menu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "العربية,")).firstMatch.tap()
        XCTAssertEqual(field.value as? String, "fictional_user")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "login-ar-input-preserved"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["demo.language.menu"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "English (United States),")).firstMatch.tap()
        XCTAssertEqual(field.value as? String, "fictional_user")
        XCTAssertEqual(app.textFields["account.input.password"].value as? String, "Fictional-Password-123")
    }
    @MainActor private func dismissPasswordSuggestion(in app: XCUIApplication) {
        // 系统提示使用模拟器系统语言；应用语言不能控制 Password AutoFill 界面。
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "关闭", "關閉", "إغلاق"])).firstMatch
        if close.waitForExistence(timeout: 12) { close.tap() }
    }
    @MainActor func testLocalFictionalRegistrationRestartEditAndLogout() throws {
        guard ProcessInfo.processInfo.environment["AZUREFISH_ACCOUNT_UI_LIVE"] == "1" else {
            throw XCTSkip("Requires explicit fictional local service")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-account-local-development", "-azurefish.locale.identifier", "en"]
        app.launch()
        let register = app.buttons["account.design.register"]
        // 前次运行若留有虚构会话，先显式退出，保留安装身份和加密缓存。
        if app.cells["account.design.signOut"].waitForExistence(timeout: 3) {
            app.cells["account.design.signOut"].tap(); app.alerts.buttons["Sign out"].tap()
        }
        XCTAssertTrue(register.waitForExistence(timeout: 15)); register.tap()
        let username = "ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let name = app.textFields["account.input.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(username)
        let fictionalPassword = "fictionalpassword"
        let password = app.secureTextFields["account.input.password"]
        password.tap()
        dismissPasswordSuggestion(in: app)
        XCTAssertTrue(app.keys["f"].waitForExistence(timeout: 5))
        app.typeText(fictionalPassword)
        app.buttons["Show password"].firstMatch.tap()
        XCTAssertEqual(app.textFields["account.input.password"].value as? String, fictionalPassword)
        app.buttons["Hide password"].tap()
        let confirm = app.secureTextFields["account.input.confirm"]
        for _ in 0..<3 where !confirm.isHittable { app.scrollViews.firstMatch.swipeUp() }
        confirm.tap()
        dismissPasswordSuggestion(in: app)
        XCTAssertTrue(app.keys["f"].waitForExistence(timeout: 5))
        app.typeText(fictionalPassword)
        let nickname = app.textFields["account.input.nickname"]
        for _ in 0..<3 where !nickname.isHittable { app.scrollViews.firstMatch.swipeUp() }
        nickname.tap(); nickname.typeText("Fictional UI")
        register.tap()
        let edit = app.cells["account.design.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        app.terminate(); app.launch()
        XCTAssertTrue(edit.waitForExistence(timeout: 20))
        let meCapture = XCTAttachment(screenshot: app.screenshot()); meCapture.name = "me-restored-live"; meCapture.lifetime = .keepAlways; add(meCapture)
        app.cells["account.design.security"].tap()
        XCTAssertTrue(app.cells["account.design.deleteAccount"].waitForExistence(timeout: 5))
        app.cells["account.design.deleteAccount"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3)); app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.cells["account.design.settings"].tap()
        XCTAssertTrue(app.cells["account.design.appearance"].waitForExistence(timeout: 5))
        let settingsCapture = XCTAttachment(screenshot: app.screenshot()); settingsCapture.name = "settings-live"; settingsCapture.lifetime = .keepAlways; add(settingsCapture)
        app.navigationBars.buttons.firstMatch.tap()
        edit.tap()
        let bio = app.textViews["account.profile.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 5)); bio.tap(); bio.typeText("Fictional simulator profile")
        app.buttons["account.design.save"].tap()
        XCTAssertTrue(app.staticTexts["Profile saved"].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "profile-saved-live"; attachment.lifetime = .keepAlways; add(attachment)
        app.navigationBars.buttons["Cancel"].tap()
        app.cells["account.design.signOut"].tap(); app.alerts.buttons["Sign out"].tap()
        XCTAssertTrue(app.buttons["account.design.accountLogin"].waitForExistence(timeout: 15))
    }
}
