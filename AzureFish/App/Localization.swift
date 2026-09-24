//
//  Localization.swift
//  Demo
//
//  Created by Codex on 2026/6/2.
//

import UIKit
import AppLocalization

@MainActor
enum Localization {
    private static let languageMenuItemAccessibilityIdentifier =
        "demo.language.menu"

    static let localizationController = LocalizationController(
        supportedLocales: [.englishUS, .simplifiedChinese, .arabic],
        fallbackLocale: .englishUS,
        preferenceStore: UserDefaultsLocalePreferenceStore(
            key: "azurefish.locale.identifier"
        )
    )

    static let resolver = LocalizedStringResolver(
        localeProvider: { localizationController.currentLocale },
        fallbackLocale: .englishUS,
        missingKeyHandler: { key, locale, _ in
            assertionFailure("Missing localization key '\(key)' for \(locale.identifier)")
        }
    )

    /// Reusable UIKit 内容每次配置或重新挂载时都通过该 context 读取最新
    /// snapshot；context 本身不会缓存创建时的语言或方向。
    static let reusableContext = UIKitLocalizationContext(
        localizationController: localizationController
    )

    /// 输入组件跟随自己的公开方向边界，兼顾独立方向演示与正常应用语言刷新。
    /// 每次读取最新快照；弱引用容器，避免输入绑定反向持有组件。
    static func inputContext(for container: UIView) -> UIKitLocalizationContext {
        UIKitLocalizationContext { [weak container] in
            layoutDirectionUpdate(
                container?.effectiveUserInterfaceLayoutDirection ?? currentUIKitDirection
            ).snapshot
        }
    }

    private static let sceneCoordinator = UIWindowSceneLocalizationCoordinator(
        localizationController: localizationController
    )
    private static var notificationToken: NSObjectProtocol?
    private static var lastDistributedSnapshot: LocalizationSnapshot?

    static var currentLayoutDirection: AppUserInterfaceLayoutDirection {
        localizationController.layoutDirection
    }

    static var currentUIKitDirection: UIUserInterfaceLayoutDirection {
        currentLayoutDirection.uiLayoutDirection
    }

    static var currentUIKitUpdate: UIKitLocalizationUpdate {
        .initial(snapshot: localizationController.currentSnapshot)
    }

    static func layoutDirectionUpdate(
        _ direction: UIUserInterfaceLayoutDirection,
        reasons: UIKitLocalizationUpdateReason = [.layoutDirection]
    ) -> UIKitLocalizationUpdate {
        let snapshot = localizationController.currentSnapshot
        if direction == snapshot.layoutDirection.uiLayoutDirection {
            return UIKitLocalizationUpdate(snapshot: snapshot, reasons: reasons)
        }
        // 仅供独立方向演示使用；正常语言刷新始终保留真实语言、选择状态和版本。
        let locale: AppLocale = direction == .rightToLeft ? .arabic : .englishUS
        return UIKitLocalizationUpdate(
            snapshot: LocalizationSnapshot(
                locale: locale,
                followsSystemLocale: false,
                revision: localizationController.currentSnapshot.revision
            ),
            reasons: reasons
        )
    }

    static func start() {
        // 方向边界只设置在窗口和控制器上。若通过 UIView appearance proxy 设置，
        // 每个新视图都会把继承方向固化为显式值，导致既有子树无法跟随运行时切换。
        guard notificationToken == nil else { return }
        lastDistributedSnapshot = localizationController.currentSnapshot
        notificationToken = NotificationCenter.default.addObserver(
            forName: LocalizationController.localizationDidChangeNotification,
            object: localizationController,
            queue: .main
        ) { notification in
            guard let change = notification.userInfo?[LocalizationController.localizationChangeUserInfoKey] as? LocalizationChange else {
                return
            }

            Task { @MainActor in
                guard change.current.revision
                    == localizationController.currentSnapshot.revision else {
                    return
                }
                // 合并的是最终状态与上次实际分发状态之间的差异，不能只保留最后一条
                // 增量通知，否则 RTL → 中文 → 英文会漏掉第一步的方向变化。
                let mergedChange = LocalizationChange(
                    previous: lastDistributedSnapshot ?? change.previous,
                    current: change.current
                )
                lastDistributedSnapshot = change.current
                // Demo 主动查找已连接场景，使没有 SceneDelegate 的交互式 #Preview 窗口
                // 也能与正式应用接收同一次原子更新。
                sceneCoordinator.reloadAllScenes(for: mergedChange)
            }
        }
    }

    static func register(window: UIWindow) {
        sceneCoordinator.register(window: window)
    }

    static func unregister(window: UIWindow) {
        sceneCoordinator.unregister(window: window)
    }

    static func synchronize(window: UIWindow) {
        sceneCoordinator.synchronize(window: window)
    }

    @discardableResult
    static func setLocale(identifier: String) -> Bool {
        if identifier == LocalizationController.followSystemLocaleIdentifier {
            return localizationController.setFollowsSystemLocale()
        }

        return localizationController.setLocale(identifier: identifier)
    }

    @discardableResult
    static func refreshSystemLocaleIfNeeded() -> Bool {
        localizationController.refreshSystemLocaleIfNeeded()
    }

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        resolver.string(key, bundle: .main, arguments: arguments)
    }

    static func text(_ key: String) -> String {
        resolver.string(key, bundle: .main)
    }

    /// 按当前应用语言格式化比例；例如 `0.72` 在英文下显示为 `72%`。
    static func percent(_ value: Double) -> String {
        value.formatted(.percent.locale(localizationController.locale))
    }

    static func localeDisplayName(_ locale: AppLocale) -> String {
        locale.localizedDisplayName(preferredBy: localizationController.currentLocale)
    }

    static func currentLanguageSummary() -> String {
        if localizationController.followsSystemLocale {
            return "\(text("language.follow.system")) (\(localizationController.currentLocale.identifier))"
        }

        return localizationController.currentLocale.identifier
    }

    static func installLanguageMenu(on viewController: UIViewController) {
        // #Preview 不会执行 AppDelegate；此处重复启动是幂等操作，可确保预览和正式应用
        // 都能监听菜单中的语言选择。
        start()
        let item = UIBarButtonItem(
            image: UIImage(systemName: "globe"),
            primaryAction: nil,
            menu: languageMenu()
        )
        item.accessibilityLabel = text("language.menu.accessibility")
        item.accessibilityIdentifier = languageMenuItemAccessibilityIdentifier
        viewController.navigationItem.setBarButtonItem(
            item,
            side: .trailing
        )
    }

    static func reloadLanguageMenu(on viewController: UIViewController) {
        let navigationItem = viewController.navigationItem
        guard let item = [
            navigationItem.leftBarButtonItem,
            navigationItem.rightBarButtonItem,
        ]
            .compactMap({ $0 })
            .first(where: {
                $0.accessibilityIdentifier
                    == languageMenuItemAccessibilityIdentifier
            }) else {
            return
        }

        item.menu = languageMenu()
        item.accessibilityLabel = text("language.menu.accessibility")
        navigationItem.setBarButtonItem(item, side: .trailing)
    }

    static func languageMenu() -> UIMenu {
        let follow = UIAction(
            title: text("language.follow.system"),
            subtitle: localeDisplayName(localizationController.currentLocale),
            image: localizationController.followsSystemLocale ? UIImage(systemName: "checkmark") : nil
        ) { _ in
            Task { @MainActor in
                setLocale(identifier: LocalizationController.followSystemLocaleIdentifier)
            }
        }

        let localeActions = localizationController.supportedLocales.map { locale in
            UIAction(
                title: locale.nativeDisplayName,
                subtitle: localeDisplayName(locale),
                image: (!localizationController.followsSystemLocale && locale == localizationController.currentLocale) ? UIImage(systemName: "checkmark") : nil
            ) { _ in
                Task { @MainActor in
                    setLocale(identifier: locale.identifier)
                }
            }
        }

        return UIMenu(
            title: text("language.menu.title"),
            image: UIImage(systemName: "globe"),
            children: [follow] + localeActions
        )
    }

}

extension UIViewController {
    @MainActor
    func installLanguageMenu() {
        Localization.installLanguageMenu(on: self)
    }

    @MainActor
    func reloadLanguageMenu() {
        Localization.reloadLanguageMenu(on: self)
    }

    @MainActor
    func applyLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        UIViewLayoutDirectionUpdater.apply(
            Localization.layoutDirectionUpdate(direction),
            to: [UIViewLayoutDirectionTarget(view, policy: .followApplication)]
        )
    }
}
