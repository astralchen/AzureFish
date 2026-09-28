import QuickLayoutKit
import Testing
import UIKit
@testable import AzureFish

@MainActor
@Suite("好友通过系统提示布局", .serialized)
struct ChatFriendshipNoticeTests {
    @Test func systemMessageUsesNoticeAndNoBubbleOrReceipt() throws {
        guard #available(iOS 26.0, *) else { return }
        let model = ChatViewModel()
        var message = Message(id: 42, direction: .incoming, content: .userText(""), sentAt: Date())
        message.systemNotice = "对方已通过你的好友申请，可以开始聊天了。"
        model.messages = [message]
        let item = try #require(model.makeState().timeline.first { $0.id == .message(42) })
        guard case .notice(let notice) = item.content else { Issue.record("Expected independent system notice"); return }
        #expect(notice.canDelete && !notice.canReedit && !notice.isSender)
        #expect(notice.text == message.systemNotice)
    }

    @Test func noticesWrapAndClearAccessibilityActionsOnReuse() throws {
        let phrases = ["对方已通过你的好友申请，可以开始聊天了。", "你已通過對方的好友申請，可以開始聊天了。",
                       "Your friend request was accepted. You can now chat.", "تم قبول طلب صداقتك. يمكنكما الدردشة الآن."]
        for width: CGFloat in [320, 390, 700] {
            for (index, phrase) in phrases.enumerated() {
                let cell = ConversationNoticeCell(frame: CGRect(x: 0, y: 0, width: width, height: 150))
                cell.semanticContentAttribute = index == 3 ? .forceRightToLeft : .forceLeftToRight
                cell.configure(.init(messageID: 1, text: phrase, canDelete: true), delete: {}, edit: {})
                cell.setNeedsQuickLayout(); cell.layoutIfNeeded()
                func labels(_ view: UIView) -> [UILabel] { (view as? UILabel).map { [$0] } ?? view.subviews.flatMap(labels) }
                let label = try #require(labels(cell).first { $0.text == phrase })
                #expect(label.numberOfLines == 0 && label.textAlignment == .center)
                #expect(label.adjustsFontForContentSizeCategory)
                let frame = label.convert(label.bounds, to: cell)
                #expect(frame.width > 0 && frame.minX >= 0 && frame.maxX <= width)
                #expect(label.accessibilityCustomActions?.count == 1)
                cell.prepareForReuse()
                #expect(label.accessibilityCustomActions == nil)
                let legacy = LiveRevokedMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 150))
                legacy.configure(text: phrase, editTitle: "", edit: nil)
                legacy.layoutIfNeeded()
                #expect(legacy.editButton.isHidden && legacy.noticeLabel.textAlignment == .center)
            }
        }
    }
}
