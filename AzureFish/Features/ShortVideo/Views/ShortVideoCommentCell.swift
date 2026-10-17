import AppLocalization
import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import UIKit

/// 按头像、昵称、正文和时间分层展示一级评论；自己的评论通过菜单或辅助功能操作删除。
final class ShortVideoCommentCell: QuickLayoutCollectionViewCell, UIContextMenuInteractionDelegate {
    private let avatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let author = UILabel(), message = UILabel(), timestamp = UILabel()
    private let more = UIButton(type: .system)
    private var deleteRequested: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        avatar.tintColor = .secondaryLabel; avatar.contentMode = .scaleAspectFit
        avatar.isAccessibilityElement = false
        for label in [author, message, timestamp] {
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0
        }
        author.font = .preferredFont(forTextStyle: .subheadline); author.textColor = .secondaryLabel
        message.font = .preferredFont(forTextStyle: .body); message.textColor = .label
        timestamp.font = .preferredFont(forTextStyle: .caption1); timestamp.textColor = .secondaryLabel
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.tintColor = .secondaryLabel; more.showsMenuAsPrimaryAction = true
        addInteraction(UIContextMenuInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(alignment: .top, spacing: 10) {
            avatar.resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                author.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                message.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                timestamp.resizable(axis: .horizontal).frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if deleteRequested != nil { more.resizable().frame(width: 44, height: 44) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    func configure(_ comment: VideoComment, delete: (() -> Void)?) {
        deleteRequested = delete
        author.text = comment.author.nickname; message.text = comment.text
        let date = Date(timeIntervalSince1970: Double(comment.createdAt) / 1000)
        timestamp.text = date.formatted(.dateTime.month().day().locale(Localization.localizationController.locale))
        timestamp.accessibilityLabel = date.formatted(.dateTime.year().month().day().hour().minute().locale(Localization.localizationController.locale))
        accessibilityIdentifier = "shortVideo.comment." + comment.id
        more.accessibilityIdentifier = "shortVideo.comment.options." + comment.id
        more.accessibilityLabel = Localization.text("shortVideo.commentOptions")
        more.menu = delete == nil ? nil : deletionMenu()
        message.accessibilityCustomActions = delete == nil ? [] : [UIAccessibilityCustomAction(name: Localization.text("shortVideo.delete"), actionHandler: { [weak self] _ in
            self?.deleteRequested?(); return true
        })]
        setNeedsQuickLayout()
    }
    private func deletionMenu() -> UIMenu {
        UIMenu(children: [UIAction(title: Localization.text("shortVideo.delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteRequested?() }])
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard deleteRequested != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self?.deletionMenu() }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        deleteRequested = nil; more.menu = nil; message.accessibilityCustomActions = nil
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频评论 · 长正文") {
    let cell = ShortVideoCommentCell(frame: .zero)
    cell.configure(.init(id: "sample", author: .init(id: "viewer", nickname: "海边散步", version: 1, avatarID: nil, deleted: false),
        text: "风吹过海面的这一刻很安静。\nThe light on the water is beautiful.", createdAt: 1_792_176_000_000), delete: {})
    return cell
}
#endif
