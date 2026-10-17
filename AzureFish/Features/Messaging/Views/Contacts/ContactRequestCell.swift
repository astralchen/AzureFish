import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 申请行的大字体布局将操作放在正文之后，避免 RTL 混合文字与头像环绕重叠。
final class ContactRequestCell: QuickLayoutCollectionViewCell {
    private let avatar = AccountAvatarView()
    private let name = UILabel(), detail = UILabel()
    private let accept = UIButton(type: .system)
    private let separator = UIView()
    private var canAccept = false
    private var accepted: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        for label in [name, detail] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        name.font = .preferredFont(forTextStyle: .body); detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel; avatar.contentMode = .scaleAspectFit
        separator.backgroundColor = .separator
        accept.addAction(UIAction { [weak self] _ in self?.accepted?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                avatar.resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 6) { name.resizable(axis: .horizontal); detail.resizable(axis: .horizontal) }
                    .frame(maxWidth: .infinity)
            }
            if canAccept { accept.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 44) }
            separator.resizable(axis: .horizontal).frame(height: 0.5)
        }.padding(.horizontal, 20).padding(.top, 16)
    }
    override func prepareForReuse() { super.prepareForReuse(); avatar.reset(); accepted = nil }
    func configure(_ contact: ChatContact, session: SessionCoordinator? = nil, detail: String, busy: Bool, accepted: @escaping () -> Void) {
        name.text = contact.peer.deleted == true ? Localization.text("account.deletedUser") : contact.displayName
        self.detail.text = detail
        if let session, let user = UUID(uuidString: contact.peer.id) {
            avatar.configure(session: session, user: user, asset: contact.peer.deleted == true ? nil : contact.peer.avatarID)
        } else { avatar.reset() }
        name.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        self.detail.textAlignment = name.textAlignment
        canAccept = contact.allows(.accept); self.accepted = accepted
        var config = UIButton.Configuration.tinted(); config.title = Localization.text("chat.live.accept")
        config.showsActivityIndicator = busy; accept.configuration = config; accept.isEnabled = !busy
        accept.titleLabel?.numberOfLines = 0
        accept.accessibilityIdentifier = "contacts.accept." + contact.peer.id
        accessibilityIdentifier = "contacts.peer." + contact.peer.id
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("好友申请行") {
    let cell = ContactRequestCell(frame: CGRect(x: 0, y: 0, width: 390, height: 260))
    cell.configure(ConversationPreviewData.contacts[2], detail: "你好，我们在设计活动中见过。\n等待确认", busy: false, accepted: {})
    return QuickLayoutHostingController { cell.resizable(axis: .horizontal) }
}
#endif
