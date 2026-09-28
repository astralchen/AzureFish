import QuickLayoutKit
import Testing
import UIKit

@testable import AzureFish

@MainActor
@Suite("撤回提示布局", .serialized)
struct ChatReeditLayoutTests {
    @Test func editActionAndReuseDoNotLeakToOtherMessages() {
        let cell = LiveRevokedMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        var count = 0
        cell.configure(text: "你撤回了一条消息", editTitle: "重新编辑", edit: { count += 1 })
        cell.editButton.sendActions(for: .touchUpInside)
        #expect(count == 1)
        cell.prepareForReuse()
        cell.configure(text: "对方撤回了一条消息", editTitle: "重新编辑", edit: nil)
        cell.editButton.sendActions(for: .touchUpInside)
        #expect(count == 1)
        #expect(cell.editButton.isHidden)
        #expect(cell.noticeLabel.text == "对方撤回了一条消息")
    }

    @Test func narrowLargeTextAndRTLKeepActionUsable() {
        let controller = UIViewController()
        controller.loadViewIfNeeded()
        let cell = LiveRevokedMessageCell(frame: .zero)
        controller.view.addSubview(cell)
        for direction: UISemanticContentAttribute in [.forceLeftToRight, .forceRightToLeft] {
            for width: CGFloat in [320, 390, 700] {
                controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
                cell.frame = CGRect(x: 0, y: 0, width: width, height: 240)
                cell.semanticContentAttribute = direction
                cell.noticeLabel.font = .systemFont(ofSize: 28)
                cell.editButton.titleLabel?.font = .systemFont(ofSize: 28)
                cell.configure(text: "一位昵称非常长的虚构群成员撤回了一条消息", editTitle: "إعادة التحرير", edit: {})
                cell.setNeedsQuickLayout()
                cell.setNeedsLayout()
                cell.layoutIfNeeded()
                #expect(cell.editButton.bounds.width >= 44)
                #expect(cell.editButton.bounds.height >= 44)
                let frame = cell.editButton.convert(cell.editButton.bounds, to: cell)
                #expect(frame.minX >= 0 && frame.maxX <= width)
                #expect(cell.noticeLabel.numberOfLines == 0)
            }
        }
    }
}
