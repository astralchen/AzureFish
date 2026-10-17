import AppLocalization
import AzureFishAPI
import AzureFishChat
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 成员网格的头像和昵称，使用默认头像避免虚构服务器未提供的资料。
final class ConversationMemberCell: QuickLayoutCollectionViewCell {
    private let avatar = UIImageView(image: UIImage(systemName: "person.crop.square.fill"))
    private let name = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        avatar.tintColor = .secondaryLabel
        avatar.contentMode = .scaleAspectFit
        name.font = .preferredFont(forTextStyle: .footnote)
        name.adjustsFontForContentSizeCategory = true
        name.numberOfLines = 2
        name.textAlignment = .center
        contentView.backgroundColor = .secondarySystemGroupedBackground
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: .center, spacing: 6) {
            avatar.resizable().frame(width: 52, height: 52)
            name.resizable(axis: .horizontal)
        }.padding(.horizontal, 4).padding(.vertical, 8)
    }
    func configure(name: String, owner: Bool) {
        self.name.text = name
        accessibilityLabel = name
        accessibilityValue = owner ? Localization.text("chat.live.owner") : nil
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("聊天成员") {
    let cell = ConversationMemberCell(frame: CGRect(x: 0, y: 0, width: 100, height: 110))
    cell.configure(name: "林沐", owner: false)
    return cell
}
#endif
