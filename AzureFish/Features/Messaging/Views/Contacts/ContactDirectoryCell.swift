import AzureFishAPI
import AzureFishChat
import AppLocalization
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 在固定尺寸的 accessory 容器中显示头像，使图片切换不改变整行的垂直对齐。
final class ContactDirectoryCell: UICollectionViewListCell {
    let avatar = AccountAvatarView()
    let avatarAccessoryView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    override init(frame: CGRect) {
        super.init(frame: frame)
        // 系统只布局普通容器，避免直接使用图片 accessory 时受图片对齐信息影响。
        avatar.frame = avatarAccessoryView.bounds
        avatar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        avatarAccessoryView.addSubview(avatar)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); avatar.reset() }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("通讯录联系人行") {
    let cell = ContactDirectoryCell(frame: CGRect(x: 0, y: 0, width: 390, height: 72))
    var content = UIListContentConfiguration.subtitleCell()
    content.text = ConversationPreviewData.contact.displayName
    content.secondaryText = ConversationPreviewData.contact.peer.nickname
    cell.contentConfiguration = content
    cell.accessories = [.customView(configuration: .init(customView: cell.avatarAccessoryView, placement: .leading(), reservedLayoutWidth: .actual, maintainsFixedSize: true))]
    return QuickLayoutHostingController { cell.resizable(axis: .horizontal).frame(height: 72) }
}
#endif
