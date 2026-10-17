#if DEBUG
import UIKit
import QuickLayoutKit
import QuickLayout

/// 提供设计状态与认证回归入口；这些声明仅在 Debug 配置中编译。
struct AccountDebugScenario {
    let id: String
    let titleKey: String
    let messageKey: String
    var actions: [(String, String)] { Self.links[id] ?? [] }
    static let all: [Self] = [
        .init(id: "welcome", titleKey: "account.design.welcome", messageKey: "account.design.operationError"),
        .init(id: "login.remembered", titleKey: "account.design.login", messageKey: "account.design.operationError"),
        .init(id: "login.empty", titleKey: "account.design.login", messageKey: "account.design.operationError"),
        .init(id: "login.filled", titleKey: "account.design.login", messageKey: "account.design.operationError"),
        .init(id: "login.focused", titleKey: "account.design.login", messageKey: "account.design.operationError"),
        .init(id: "login.error", titleKey: "account.design.login", messageKey: "account.design.loginError"),
        .init(id: "login.loading", titleKey: "account.design.login", messageKey: "account.design.operationError"),
        .init(id: "login.offline", titleKey: "account.design.login", messageKey: "account.design.offline"),
        .init(id: "login.timeout", titleKey: "account.design.login", messageKey: "account.design.timeout"),
        .init(id: "login.passwordVisible", titleKey: "account.design.login", messageKey: "account.design.showPassword"),
        .init(id: "register.empty", titleKey: "account.design.register", messageKey: "account.design.operationError"),
        .init(id: "register.mismatch", titleKey: "account.design.register", messageKey: "account.design.operationError"),
        .init(id: "register.taken", titleKey: "account.design.register", messageKey: "account.design.operationError"),
        .init(id: "register.loading", titleKey: "account.design.register", messageKey: "account.design.operationError"),
        .init(id: "register.offline", titleKey: "account.design.register", messageKey: "account.design.offline"),
        .init(id: "apple.handoff", titleKey: "account.design.appleHandoff", messageKey: "account.design.operationError"),
        .init(id: "apple.cancelled", titleKey: "account.design.welcome", messageKey: "account.design.appleCancelled"),
        .init(id: "apple.failed", titleKey: "account.design.welcome", messageKey: "account.design.appleFailure"),
        .init(id: "apple.conflict", titleKey: "account.design.welcome", messageKey: "account.design.appleConflict"),
        .init(id: "complete", titleKey: "account.design.completeProfile", messageKey: "account.design.operationError"),
        .init(id: "complete.failed", titleKey: "account.design.completeProfile", messageKey: "account.design.saveError"),
        .init(id: "complete.skipped", titleKey: "account.design.completeProfile", messageKey: "account.design.incomplete"),
        .init(id: "me", titleKey: "account.design.me", messageKey: "account.design.operationError"),
        .init(id: "me.long", titleKey: "account.design.me", messageKey: "account.design.operationError"),
        .init(id: "me.incomplete", titleKey: "account.design.me", messageKey: "account.design.incomplete"),
        .init(id: "me.offline", titleKey: "account.design.me", messageKey: "account.design.offlineProfile"),
        .init(id: "me.loading", titleKey: "account.design.me", messageKey: "account.design.loading"),
        .init(id: "storage", titleKey: "account.design.storageUnavailable", messageKey: "account.design.operationError"),
        .init(id: "recovery", titleKey: "account.design.recovery", messageKey: "account.design.operationError"),
        .init(id: "edit", titleKey: "account.design.editProfile", messageKey: "account.design.operationError"),
        .init(id: "edit.dirty", titleKey: "account.design.editProfile", messageKey: "account.design.operationError"),
        .init(id: "edit.saving", titleKey: "account.design.editProfile", messageKey: "account.design.saving"),
        .init(id: "edit.error", titleKey: "account.design.editProfile", messageKey: "account.design.saveError"),
        .init(id: "edit.conflict", titleKey: "account.design.editProfile", messageKey: "account.design.conflictHelp"),
        .init(id: "edit.saved", titleKey: "account.design.editProfile", messageKey: "account.design.saved"),
        .init(id: "edit.reloaded", titleKey: "account.design.conflictTitle", messageKey: "account.design.operationError"),
        .init(id: "edit.discard", titleKey: "account.design.discard", messageKey: "account.design.operationError"),
        .init(id: "nickname", titleKey: "account.design.nickname", messageKey: "account.design.operationError"),
        .init(id: "bio", titleKey: "account.design.bio", messageKey: "account.design.operationError"),
        .init(id: "avatar", titleKey: "account.design.avatar", messageKey: "account.design.operationError"),
        .init(id: "avatar.preview", titleKey: "account.design.photoPreview", messageKey: "account.design.operationError"),
        .init(id: "avatar.uploading", titleKey: "account.design.photoPreview", messageKey: "account.design.uploading"),
        .init(id: "avatar.failed", titleKey: "account.design.photoPreview", messageKey: "account.design.uploadFailed"),
        .init(id: "avatar.format", titleKey: "account.design.photoPreview", messageKey: "account.design.staticPhoto"),
        .init(id: "avatar.permission", titleKey: "account.design.photoPermission", messageKey: "account.design.operationError"),
        .init(id: "avatar.restore", titleKey: "account.design.restorePhoto", messageKey: "account.design.operationError"),
        .init(id: "security.password", titleKey: "account.design.security", messageKey: "account.design.operationError"),
        .init(id: "security.apple", titleKey: "account.design.security", messageKey: "account.design.operationError"),
        .init(id: "security.both", titleKey: "account.design.security", messageKey: "account.design.operationError"),
        .init(id: "methods.password", titleKey: "account.design.methods", messageKey: "account.design.operationError"),
        .init(id: "methods.apple", titleKey: "account.design.methods", messageKey: "account.design.operationError"),
        .init(id: "methods.both", titleKey: "account.design.methods", messageKey: "account.design.operationError"),
        .init(id: "methods.binding", titleKey: "account.design.methods", messageKey: "account.design.operationError"),
        .init(id: "methods.revoked", titleKey: "account.design.methods", messageKey: "account.design.operationError"),
        .init(id: "methods.conflict", titleKey: "account.design.methods", messageKey: "account.design.appleConflict"),
        .init(id: "reauth.password", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "reauth.apple", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "reauth.bind", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "reauth.delete", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "reauth.all", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "reauth.expired", titleKey: "account.design.reauth", messageKey: "account.design.reauthExpired"),
        .init(id: "setPassword", titleKey: "account.design.setPassword", messageKey: "account.design.operationError"),
        .init(id: "changePassword", titleKey: "account.design.changePassword", messageKey: "account.design.operationError"),
        .init(id: "password.error", titleKey: "account.design.changePassword", messageKey: "account.design.operationError"),
        .init(id: "password.loading", titleKey: "account.design.changePassword", messageKey: "account.design.operationError"),
        .init(id: "password.changed", titleKey: "account.design.changePassword", messageKey: "account.design.passwordChanged"),
        .init(id: "password.set", titleKey: "account.design.setPassword", messageKey: "account.design.passwordSet"),
        .init(id: "unbind", titleKey: "account.design.unbindApple", messageKey: "account.design.operationError"),
        .init(id: "reauth.unbind", titleKey: "account.design.reauth", messageKey: "account.design.operationError"),
        .init(id: "unbind.processing", titleKey: "account.design.unbindApple", messageKey: "account.design.unbinding"),
        .init(id: "logout", titleKey: "account.design.signOut", messageKey: "account.design.operationError"),
        .init(id: "logout.offline", titleKey: "account.design.signOut", messageKey: "account.design.operationError"),
        .init(id: "logoutAll", titleKey: "account.design.signOutAll", messageKey: "account.design.operationError"),
        .init(id: "logoutAll.confirm", titleKey: "account.design.signOutAll", messageKey: "account.design.operationError"),
        .init(id: "logoutAll.error", titleKey: "account.design.signOutAll", messageKey: "account.design.operationError"),
        .init(id: "delete", titleKey: "account.design.deleteAccount", messageKey: "account.design.operationError"),
        .init(id: "delete.confirm", titleKey: "account.design.deleteFinal", messageKey: "account.design.operationError"),
        .init(id: "delete.loading", titleKey: "account.design.deleteAccount", messageKey: "account.design.processing"),
        .init(id: "delete.offline", titleKey: "account.design.deleteAccount", messageKey: "account.design.offline"),
        .init(id: "delete.error", titleKey: "account.design.deleteAccount", messageKey: "account.design.operationError"),
        .init(id: "delete.accepted", titleKey: "account.design.deleteAccepted", messageKey: "account.design.operationError"),
        .init(id: "session", titleKey: "account.design.sessionExpired", messageKey: "account.design.operationError"),
        .init(id: "settings", titleKey: "account.design.settings", messageKey: "account.design.operationError"),
        .init(id: "appearance.system", titleKey: "account.design.appearance", messageKey: "account.design.operationError"),
        .init(id: "appearance.light", titleKey: "account.design.appearance", messageKey: "account.design.operationError"),
        .init(id: "appearance.dark", titleKey: "account.design.appearance", messageKey: "account.design.operationError"),
        .init(id: "language.system", titleKey: "account.design.language", messageKey: "account.design.operationError"),
        .init(id: "language.zh-Hans", titleKey: "account.design.language", messageKey: "account.design.operationError"),
        .init(id: "language.zh-Hant", titleKey: "account.design.language", messageKey: "account.design.operationError"),
        .init(id: "language.en", titleKey: "account.design.language", messageKey: "account.design.operationError"),
        .init(id: "language.ar", titleKey: "account.design.language", messageKey: "account.design.operationError"),
        .init(id: "demo", titleKey: "account.design.localDemo", messageKey: "account.design.operationError"),
        .init(id: "welcome.appearance", titleKey: "account.design.appearance", messageKey: "account.design.operationError"),
        .init(id: "welcome.language", titleKey: "account.design.language", messageKey: "account.design.operationError"),    ]
    private static let links: [String: [(String, String)]] = [
        "login.empty": [("account.design.signIn", "login.filled")],
        "login.filled": [("account.design.signIn", "me")],
        "login.focused": [("account.design.signIn", "me")],
        "login.error": [("account.design.signIn", "me")],
        "login.loading": [("account.design.processing", "me")],
        "login.offline": [("account.design.signIn", "me")],
        "login.timeout": [("account.design.signIn", "me")],
        "login.passwordVisible": [("account.design.signIn", "me")],
        "register.empty": [("account.design.register", "register.mismatch")],
        "register.mismatch": [("account.design.register", "me")],
        "register.taken": [("account.design.register", "me")],
        "register.loading": [("account.design.processing", "me")],
        "register.offline": [("account.design.register", "me")],
        "apple.handoff": [("account.design.openApple", "complete"), ("account.design.cancel", "apple.cancelled")],
        "complete": [("account.design.done", "me"), ("account.design.later", "me.incomplete")],
        "complete.failed": [("account.design.done", "me"), ("account.design.later", "me.incomplete")],
        "complete.skipped": [("account.design.done", "me"), ("account.design.later", "me.incomplete")],
        "me": [("account.design.signOut", "logout"), ("account.design.editProfile", "edit"), ("account.design.security", "security.password"), ("account.design.settings", "settings")],
        "me.long": [("account.design.signOut", "logout"), ("account.design.editProfile", "edit"), ("account.design.security", "security.password"), ("account.design.settings", "settings")],
        "me.incomplete": [("account.design.signOut", "logout"), ("account.design.editProfile", "edit"), ("account.design.security", "security.password"), ("account.design.settings", "settings")],
        "me.offline": [("account.design.signOut", "logout"), ("account.design.editProfile", "edit"), ("account.design.security", "security.password"), ("account.design.settings", "settings")],
        "me.loading": [("account.design.signOut", "logout"), ("account.design.editProfile", "edit"), ("account.design.security", "security.password"), ("account.design.settings", "settings")],
        "storage": [("account.design.retry", "me"), ("account.design.recovery", "recovery")],
        "recovery": [("account.design.retry", "storage")],
        "edit": [("account.design.save", "edit.saved")],
        "edit.dirty": [("account.design.save", "edit.saved")],
        "edit.saving": [("account.design.saving", "edit.saved")],
        "edit.error": [("account.design.save", "edit.saved")],
        "edit.conflict": [("account.design.reload", "edit.reloaded"), ("account.design.cancel", "me")],
        "edit.saved": [("account.design.save", "edit.saved")],
        "edit.reloaded": [("account.design.reviewSave", "edit.saved"), ("account.design.cancel", "edit")],
        "edit.discard": [("account.design.discard", "me"), ("account.design.keepEditing", "edit.dirty")],
        "nickname": [("account.design.save", "edit.saved")],
        "bio": [("account.design.save", "edit.saved")],
        "avatar": [("account.design.choosePhoto", "avatar.preview"), ("account.design.restorePhoto", "avatar.restore")],
        "avatar.preview": [("account.design.usePhoto", "avatar.uploading"), ("account.design.cancel", "edit")],
        "avatar.uploading": [("account.design.uploading", "edit"), ("account.design.cancel", "edit")],
        "avatar.failed": [("account.design.retry", "edit"), ("account.design.cancel", "edit")],
        "avatar.format": [("account.design.usePhoto", "edit"), ("account.design.cancel", "edit")],
        "avatar.permission": [("account.design.openSettings", "avatar"), ("account.design.cancel", "edit")],
        "avatar.restore": [("account.design.restorePhoto", "edit"), ("account.design.cancel", "avatar")],
        "security.password": [("account.design.methods", "methods.password"), ("account.design.changePassword", "reauth.password"), ("account.design.signOutAll", "logoutAll"), ("account.design.deleteAccount", "delete")],
        "security.apple": [("account.design.methods", "methods.apple"), ("account.design.setPassword", "reauth.apple"), ("account.design.signOutAll", "logoutAll"), ("account.design.deleteAccount", "delete")],
        "security.both": [("account.design.methods", "methods.both"), ("account.design.changePassword", "reauth.password"), ("account.design.signOutAll", "logoutAll"), ("account.design.deleteAccount", "delete")],
        "methods.password": [("account.design.bindApple", "reauth.bind"), ("account.design.passwordMethod", "changePassword"), ("account.design.appleMethod", "reauth.bind")],
        "methods.apple": [("account.design.passwordMethod", "reauth.apple"), ("account.design.appleMethod", "unbind")],
        "methods.both": [("account.design.passwordMethod", "changePassword"), ("account.design.appleMethod", "unbind")],
        "methods.binding": [("account.design.passwordMethod", "changePassword"), ("account.design.appleMethod", "unbind")],
        "methods.revoked": [("account.design.reauthorize", "apple.handoff"), ("account.design.passwordMethod", "changePassword"), ("account.design.appleMethod", "apple.handoff")],
        "methods.conflict": [("account.design.cancel", "security.both"), ("account.design.passwordMethod", "changePassword"), ("account.design.appleMethod", "unbind")],
        "reauth.password": [("account.design.confirmIdentity", "changePassword"), ("account.design.cancel", "security.password")],
        "reauth.apple": [("account.design.openApple", "setPassword"), ("account.design.cancel", "security.apple")],
        "reauth.bind": [("account.design.confirmIdentity", "methods.binding"), ("account.design.cancel", "security.password")],
        "reauth.delete": [("account.design.confirmIdentity", "delete.confirm"), ("account.design.cancel", "delete")],
        "reauth.all": [("account.design.confirmIdentity", "logoutAll.confirm"), ("account.design.cancel", "logoutAll")],
        "reauth.expired": [("account.design.confirmIdentity", "changePassword"), ("account.design.cancel", "security.password")],
        "setPassword": [("account.design.save", "password.set")],
        "changePassword": [("account.design.save", "password.changed")],
        "password.error": [("account.design.save", "password.changed")],
        "password.loading": [("account.design.processing", "password.changed")],
        "password.changed": [("account.design.signIn", "login.empty")],
        "password.set": [("account.design.done", "security.both")],
        "unbind": [("account.design.continue", "reauth.unbind"), ("account.design.cancel", "methods.both")],
        "reauth.unbind": [("account.design.confirmIdentity", "unbind.processing")],
        "unbind.processing": [("account.design.processing", "methods.password")],
        "logout": [("account.design.signOut", "welcome"), ("account.design.cancel", "me")],
        "logout.offline": [("account.design.localLogout", "welcome"), ("account.design.cancel", "me.offline")],
        "logoutAll": [("account.design.continue", "reauth.all")],
        "logoutAll.confirm": [("account.design.signOutAll", "welcome"), ("account.design.cancel", "security.password")],
        "logoutAll.error": [("account.design.retry", "reauth.all"), ("account.design.cancel", "security.password")],
        "delete": [("account.design.continue", "reauth.delete")],
        "delete.confirm": [("account.design.deleteConfirm", "delete.loading"), ("account.design.cancel", "security.password")],
        "delete.loading": [("account.design.processing", "delete.accepted"), ("account.design.cancel", "security.password")],
        "delete.offline": [("account.design.retry", "reauth.delete"), ("account.design.cancel", "security.password")],
        "delete.error": [("account.design.retry", "reauth.delete"), ("account.design.cancel", "security.password")],
        "delete.accepted": [("account.design.backWelcome", "welcome")],
        "session": [("account.design.signIn", "login.empty")],
        "settings": [("account.design.appearance", "appearance.system"), ("account.design.language", "language.system")],
        "appearance.system": [("account.design.system", "appearance.system"), ("account.design.light", "appearance.light"), ("account.design.dark", "appearance.dark")],
        "appearance.light": [("account.design.system", "appearance.system"), ("account.design.light", "appearance.light"), ("account.design.dark", "appearance.dark")],
        "appearance.dark": [("account.design.system", "appearance.system"), ("account.design.light", "appearance.light"), ("account.design.dark", "appearance.dark")],
        "language.system": [("account.design.system", "language.system"), ("account.design.continue", "language.zh-Hans"), ("account.design.continue", "language.zh-Hant"), ("account.design.continue", "language.en"), ("account.design.continue", "language.ar")],
        "language.zh-Hans": [("account.design.system", "language.system"), ("account.design.continue", "language.zh-Hans"), ("account.design.continue", "language.zh-Hant"), ("account.design.continue", "language.en"), ("account.design.continue", "language.ar")],
        "language.zh-Hant": [("account.design.system", "language.system"), ("account.design.continue", "language.zh-Hans"), ("account.design.continue", "language.zh-Hant"), ("account.design.continue", "language.en"), ("account.design.continue", "language.ar")],
        "language.en": [("account.design.system", "language.system"), ("account.design.continue", "language.zh-Hans"), ("account.design.continue", "language.zh-Hant"), ("account.design.continue", "language.en"), ("account.design.continue", "language.ar")],
        "language.ar": [("account.design.system", "language.system"), ("account.design.continue", "language.zh-Hans"), ("account.design.continue", "language.zh-Hant"), ("account.design.continue", "language.en"), ("account.design.continue", "language.ar")],
        "demo": [("account.design.back", "me")],
        "welcome.appearance": [("account.design.done", "welcome")],
        "welcome.language": [("account.design.done", "welcome")],
    ]
    @MainActor
    static func controller(arguments: [String]) -> UIViewController? {
        guard let flag = arguments.firstIndex(of: "-account-scenario"), arguments.indices.contains(flag + 1) else { return nil }
        let id = arguments[flag + 1]
        let root: UIViewController
        if id == "index" { root = AccountScenarioIndexController() }
        else if let scenario = all.first(where: { $0.id == id }) { root = scenario.makeController() }
        else { return nil }
        if root is ProfileSplitViewController { return root }
        return AppNavigationController(rootViewController: root)
    }
    @MainActor
    func makeController() -> UIViewController {
        // 场景不注入网络服务，因此不会发出真实账号操作。
        let keys = KeychainValueStore()
        let session = SessionCoordinator(service: nil, store: CredentialStore(values: keys, environmentID: "preview"),
            repository: UserRepository(root: FileManager.default.temporaryDirectory.appendingPathComponent("AccountPreview"), keys: keys, environment: "preview"))
        if id == "welcome" || id.hasPrefix("welcome.") { return WelcomeViewController(session: session) }
        if id == "login.remembered" {
            return AuthenticationViewController(session: session, register: false,
                remembered: .init(environmentID: "preview", userID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, accountName: "fictional_user"))
        }
        if id.hasPrefix("login.") || id.hasPrefix("register.") {
            let controller = AuthenticationViewController(session: session, register: id.hasPrefix("register."))
            controller.loadViewIfNeeded(); controller.applyDebugState(id)
            return controller
        }
        if id.hasPrefix("me") || id == "edit" {
            session.installDebugProfile(long: id == "me.long", offline: id == "me.offline")
            if id == "edit", let profile = session.profile { return EditProfileViewController(session: session, profile: profile) }
            return ProfileSplitViewController(session: session, runtime: ChatRuntime(session: session))
        }
        if id == "security.password" { return AccountSecurityViewController(session: session) }
        if id.hasPrefix("appearance.") || id.hasPrefix("language.") || id == "settings" { return AccountSettingsViewController() }
        return AccountScenarioViewController(scenario: self)
    }
}
#endif
