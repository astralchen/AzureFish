import UIKit
import Testing
@testable import AzureFish

/// 检查真实集合列表的尺寸与跨页面偏好刷新，不代替多窗口真机验证。
@Suite("设置列表", .serialized)
@MainActor
struct AccountSettingsTests {
    private func settle(_ controller: AccountSettingsViewController) async {
        for _ in 0..<12 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            controller.collectionView.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @Test func rowsFitNarrowWideAndAccessibilityText() async {
        let controller = AccountSettingsViewController()
        controller.loadViewIfNeeded()
        for width: CGFloat in [320, 390, 1024] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1000)
            await settle(controller)
            #expect(controller.collectionView.numberOfSections == 2)
            for section in 0..<2 {
                let item = IndexPath(item: 0, section: section)
                let attributes = controller.collectionView.layoutAttributesForItem(at: item)
                #expect(attributes != nil)
                if let frame = attributes?.frame {
                    #expect(frame.width <= 600.5)
                    #expect(frame.minX >= 23.5 && frame.maxX <= width - 23.5)
                    #expect(frame.height >= 44)
                }
                let footerPath = IndexPath(item: 0, section: section)
                if let footer = controller.collectionView.supplementaryView(forElementKind: UICollectionView.elementKindSectionFooter, at: footerPath) {
                    footer.layoutIfNeeded()
                    let labels = footer.subviews.compactMap { $0 as? UILabel }
                    #expect(!labels.isEmpty)
                    for label in labels {
                        let fitted = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                        #expect(label.bounds.height >= ceil(fitted.height) - 1)
                    }
                }
            }
        }
        if #available(iOS 17.0, *) {
            controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
            controller.view.frame.size.width = 320
            await settle(controller)
            let cell = controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
            #expect((cell?.bounds.height ?? 0) > 70)
        }
    }
    @Test func appearanceChangeRefreshesTwoLoadedPages() async {
        let original = AppearancePreference.choice
        defer { AppearancePreference.select(original) }
        let pages = [AccountSettingsViewController(), AccountSettingsViewController()]
        for page in pages { page.loadViewIfNeeded(); page.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844) }
        for choice in [AppearancePreference.Choice.dark, .system] {
            AppearancePreference.select(choice)
            for page in pages {
                await settle(page)
                let cell = page.collectionView.cellForItem(at: IndexPath(item: 0, section: 0))
                #expect(cell?.accessibilityValue == Localization.text("account.design.\(choice.rawValue)"))
            }
        }
    }
}
