//
//  LocalizedViewControllers.swift
//  Demo
//
//  Created by Codex on 2026/6/2.
//

import UIKit
import AppLocalization
import QuickLayoutKit

/// 两种基础控制器共用刷新顺序；各页面的方向钩子负责自己拥有的视图边界。
@MainActor
private enum LocalizedScreenUpdater {
    static func apply(
        _ update: UIKitLocalizationUpdate,
        reloadDirection: (UIUserInterfaceLayoutDirection) -> Void,
        reloadContent: () -> Void
    ) {
        if update.requiresLayoutDirectionRefresh {
            reloadDirection(update.layoutDirection)
        }
        if update.requiresLocalizedContentRefresh {
            reloadContent()
        }
    }

    static func reloadTitle(on controller: UIViewController, key: String?) {
        if let key {
            controller.title = Localization.text(key)
            controller.navigationItem.title = controller.title
        }
        controller.reloadLanguageMenu()
    }
}

class LocalizedQuickLayoutHostingController: QuickLayoutHostingController, UIKitLocalizationApplying {
    var localizedTitleKey: String? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        installLanguageMenu()
        applyLocalization(
            .initial(snapshot: Localization.localizationController.currentSnapshot)
        )
    }

    func applyLocalization(_ update: UIKitLocalizationUpdate) {
        LocalizedScreenUpdater.apply(
            update,
            reloadDirection: reloadLayoutDirection,
            reloadContent: reloadLocalizedContent
        )
    }

    func reloadLocalizedContent() {
        LocalizedScreenUpdater.reloadTitle(on: self, key: localizedTitleKey)
        setNeedsQuickLayout()
    }

    func reloadLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        applyLayoutDirection(direction)
        setNeedsQuickLayout()
    }
}

class LocalizedViewController: UIViewController, UIKitLocalizationApplying {
    var localizedTitleKey: String? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        installLanguageMenu()
        applyLocalization(
            .initial(snapshot: Localization.localizationController.currentSnapshot)
        )
    }

    func applyLocalization(_ update: UIKitLocalizationUpdate) {
        LocalizedScreenUpdater.apply(
            update,
            reloadDirection: reloadLayoutDirection,
            reloadContent: reloadLocalizedContent
        )
    }

    func reloadLocalizedContent() {
        LocalizedScreenUpdater.reloadTitle(on: self, key: localizedTitleKey)
    }

    func reloadLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        applyLayoutDirection(direction)
    }
}

@available(iOS 17.0, *)
#Preview {
   UINavigationController(rootViewController: LocalizedQuickLayoutHostingController())
}
