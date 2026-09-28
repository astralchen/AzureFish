import QuickLayout
import QuickLayoutKit
import UIKit

/// 展示系统或撤回提示及可选的重新编辑操作，不呈现消息气泡、发送者行或回执。
final class LiveRevokedMessageCell: QuickLayoutCollectionViewCell {
    let noticeLabel = UILabel()
    let editButton = UIButton(type: .system)
    private var edit: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.textAlignment = .center
        noticeLabel.numberOfLines = 0
        editButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        editButton.titleLabel?.adjustsFontForContentSizeCategory = true
        editButton.titleLabel?.numberOfLines = 0
        editButton.titleLabel?.textAlignment = .center
        editButton.tintColor = .systemBlue
        editButton.accessibilityIdentifier = "chat.reedit"
        editButton.addAction(UIAction { [weak self] _ in self?.edit?() }, for: .touchUpInside)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var body: Layout {
        let fitsInline =
            !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            && noticeLabel.intrinsicContentSize.width
                + max(44, editButton.intrinsicContentSize.width) + 48 <= contentView.bounds.width
        if !editButton.isHidden && fitsInline {
            return HStack(alignment: .center, spacing: 6) {
                Spacer()
                noticeLabel
                editButton.frame(minWidth: 44, minHeight: 44)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 8)
        } else {
            return VStack(alignment: .center, spacing: 0) {
                noticeLabel.resizable(axis: .horizontal)
                if !editButton.isHidden {
                    editButton.resizable(axis: .horizontal).frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal, 20).padding(.vertical, 8)
        }
    }

    func configure(text: String, editTitle: String, edit: (() -> Void)?) {
        noticeLabel.text = text
        editButton.setTitle(editTitle, for: .normal)
        editButton.isHidden = edit == nil
        self.edit = edit
        setNeedsQuickLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        edit = nil
        editButton.isHidden = true
        noticeLabel.text = nil
    }
}

#if DEBUG
    @available(iOS 17.0, *)
    #Preview("撤回后重新编辑") {
        let cell = LiveRevokedMessageCell(frame: CGRect(x: 0, y: 0, width: 390, height: 90))
        cell.configure(
            text: Localization.text("chat.live.revokedSelf"),
            editTitle: Localization.text("chat.live.reedit"), edit: {})
        return cell
    }
    @available(iOS 17.0, *)
    #Preview("他人撤回") {
        let cell = LiveRevokedMessageCell(frame: CGRect(x: 0, y: 0, width: 320, height: 70))
        cell.configure(text: Localization.text("chat.live.revokedOther"), editTitle: "", edit: nil)
        return cell
    }
#endif
