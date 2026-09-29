import UIKit
import QuickLayoutKit
import Testing
@testable import AzureFish

/// 在同一模拟器内改变内容容器，不把这些组件检查视为 iPad 真机验收。
@Suite("账号布局与系统 Keychain", .serialized)
@MainActor
struct AccountLayoutTests {
    @Test func realKeychainRoundTripUsesUniqueDisposableItem() throws {
        let store = KeychainValueStore()
        let key = "acceptance.\(UUID().uuidString)"
        defer { try? store.remove(key) }
        #expect(try store.read(key) == nil)
        try store.write(Data("fictional-test-value".utf8), key: key)
        #expect(try store.read(key) == Data("fictional-test-value".utf8))
        try store.write(Data("replacement".utf8), key: key)
        #expect(try store.read(key) == Data("replacement".utf8))
        try store.remove(key)
        #expect(try store.read(key) == nil)
    }

    @Test func welcomeActionsFillNarrowAndWideContainers() {
        let controller = WelcomeViewController(session: .configured())
        controller.loadViewIfNeeded()
        for width: CGFloat in [320, 390, 700, 1024] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            controller.setNeedsQuickLayout(); controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
            for action in controller.actions {
                #expect(abs(action.bounds.width - min(440, width - 48)) < 1)
                #expect(action.bounds.height >= 44)
                let frame = action.convert(action.bounds, to: controller.view)
                #expect(frame.minX >= 0 && frame.maxX <= width)
            }
        }
    }

    @Test func accessibilityLoginActionsScrollWithoutOverlapping() {
        guard #available(iOS 17.0, *) else { return }
        let controller = AuthenticationViewController(session: .configured(), register: false,
            remembered: .init(environmentID: "preview", userID: UUID(), accountName: "fictional_user"))
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.setNeedsQuickLayout(); controller.view.layoutIfNeeded()
        let frames = controller.actions.map { $0.convert($0.bounds, to: controller.scroll) }
        #expect(controller.actions.allSatisfy { $0.isDescendant(of: controller.scroll) })
        for (previous, next) in zip(frames, frames.dropFirst()) {
            #expect(previous.maxY <= next.minY)
        }
        #expect(frames.allSatisfy { $0.height >= 52 && $0.width > 300 })
    }

    @Test func settingsFooterIgnoresEstimatedHeightWhenMeasuringLongText() {
        let footer = SettingsFooterView(frame: .zero)
        footer.configure(key: "account.design.appearanceHelp")
        let estimated = footer.sizeThatFits(CGSize(width: 160, height: 44))
        let unlimited = footer.sizeThatFits(CGSize(width: 160, height: CGFloat.greatestFiniteMagnitude))
        #expect(estimated == unlimited)
        #expect(estimated.height > 44)
    }
}
