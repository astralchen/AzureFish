import UIKit

/// 安装级外观偏好，窗口在显示首帧前应用；账号生命周期不修改此值。
@MainActor
enum AppearancePreference {
    enum Choice: String, CaseIterable { case system, light, dark }
    static let key = "azurefish.appearance.preference"
    /// 用户选择改变且所有现有窗口应用外观后，在主线程发送；解析颜色相同也会发送。
    static let didChangeNotification = Notification.Name("AzureFish.appearancePreferenceDidChange")
    static var choice: Choice { Choice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
    static func apply(to window: UIWindow) {
        window.overrideUserInterfaceStyle = choice == .system ? .unspecified : choice == .light ? .light : .dark
    }
    static func select(_ value: Choice) {
        let previous = choice
        UserDefaults.standard.set(value.rawValue, forKey: key)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { apply(to: window) }
        }
        if previous != value { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
    }
    static func menu() -> UIMenu {
        UIMenu(title: Localization.text("account.design.appearance"), children: Choice.allCases.map { value in
            UIAction(title: Localization.text("account.design.\(value.rawValue)"), state: choice == value ? .on : .off) { _ in select(value) }
        })
    }
}
