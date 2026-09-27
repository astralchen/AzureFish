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
}
