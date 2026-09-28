import QuickLayoutKit
import Testing
import UIKit

@testable import AzureFish

@MainActor
@Suite("列表数量徽标", .serialized)
struct ChatUnreadBadgeTests {
    private func badges(in view: UIView) -> [UnreadCountBadgeView] {
        (view as? UnreadCountBadgeView).map { [$0] } ?? view.subviews.flatMap { badges(in: $0) }
    }

    @Test func badgesKeepPaddedSizeInRealListAndDisappearOnReuse() async throws {
        let controller = LiveChatListController(runtime: ChatRuntime(session: .configured()))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        controller.loadViewIfNeeded()
        for width: CGFloat in [320, 390, 700] {
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
                controller.view.semanticContentAttribute = direction
                controller.list.semanticContentAttribute = direction
                controller.rows = ["1", "12", "99+"].enumerated().map {
                    LiveChatRow(id: "badge-\($0.offset)", title: "新的朋友 · 一位名字很长的好友",
                        subtitle: "等待确认", symbol: "person.badge.plus", badge: $0.element)
                }
                controller.setNeedsQuickLayout()
                controller.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                controller.list.layoutIfNeeded()
                for index in 0..<3 {
                    let cell = try #require(controller.list.cellForItem(at: IndexPath(item: index, section: 0)))
                    cell.layoutIfNeeded()
                    let badge = try #require(badges(in: cell).first)
                    let textWidth = ceil((badge.textLabel.text! as NSString).size(withAttributes: [.font: badge.textLabel.font!]).width)
                    #expect(badge.bounds.width >= max(22, textWidth + 12) - 1)
                    #expect(badge.bounds.height >= 22)
                    let frame = badge.convert(badge.bounds, to: cell)
                    #expect(frame.minX >= 0 && frame.maxX <= cell.bounds.width)
                    #expect(abs(frame.midY - cell.bounds.midY) <= 0.5)
                    badge.layoutIfNeeded()
                    #expect(abs(badge.textLabel.center.y - badge.bounds.midY) <= 0.5)
                    #expect(badge.textLabel.textColor == .white)
                    #expect(!badge.isAccessibilityElement)
                }
                if width == 390 && direction == .forceLeftToRight {
                    let last = try #require(controller.list.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
                    let bounds = CGRect(x: 0, y: 0, width: width, height: ceil(last.frame.maxY))
                    let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
                        controller.list.layer.render(in: context.cgContext)
                    }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-unread-badges.png")
                    try image.pngData()?.write(to: url)
                    print("CHAT_BADGE_CAPTURE \(url.path)")
                }
            }
        }
        controller.rows = [LiveChatRow(id: "badge-0", title: "新的朋友")]
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.list.layoutIfNeeded()
        let cell = try #require(controller.list.cellForItem(at: IndexPath(item: 0, section: 0)))
        #expect(badges(in: cell).isEmpty)
    }
}
