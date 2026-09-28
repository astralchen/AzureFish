import QuickLayout
import QuickLayoutKit
import UIKit

/// 呈现群成员名、连接提示、系统事件与撤回结果，保持正文气泡的原版排布。
final class ConversationNoticeCell: QuickLayoutCollectionViewCell, UIContextMenuInteractionDelegate {
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private var sender = false
    private var deletable = false
    private var edit: (() -> Void)?
    private var deleteNotice: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        addInteraction(UIContextMenuInteraction(delegate: self))
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        button.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { [weak self] _ in self?.edit?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: sender ? .leading : .center, spacing: 2) {
            label.resizable(axis: .horizontal)
            if !button.isHidden { button.frame(minHeight: 44) }
        }.padding(.horizontal, 12).padding(.vertical, 4).frame(minHeight: deletable ? 44 : 0)
    }
    func configure(_ notice: ConversationNotice, delete: (() -> Void)? = nil, edit: @escaping () -> Void) {
        deletable = notice.canDelete
        deleteNotice = notice.canDelete ? delete : nil
        label.accessibilityCustomActions = deleteNotice == nil ? nil : [UIAccessibilityCustomAction(name: Localization.text("chat.live.localDelete"), actionHandler: { [weak self] _ in
            self?.deleteNotice?(); return true
        })]
        sender = notice.isSender
        label.text = notice.text
        label.textAlignment = sender ? .natural : .center
        button.isHidden = !notice.canReedit
        button.setTitle(Localization.text("chat.live.reedit"), for: .normal)
        self.edit = notice.canReedit ? edit : nil
        setNeedsQuickLayout()
    }
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard deleteNotice != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: Localization.text("chat.live.localDelete"), attributes: .destructive) { [weak self] _ in self?.deleteNotice?() }])
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        deleteNotice = nil
        edit = nil
        label.accessibilityCustomActions = nil
        label.text = nil
        button.isHidden = true
    }

}
#if DEBUG
@available(iOS 17.0, *)
#Preview("撤回提示") {
    let view = ConversationNoticeCell(frame: .zero)
    view.configure(.init(messageID: 1, text: "你撤回了一条消息", canReedit: true), edit: {})
    return view
}
#endif

#if DEBUG
@available(iOS 17.0, *)
#Preview("好友通过 · 系统提示") {
    let view = ConversationNoticeCell(frame: .zero)
    view.configure(.init(messageID: 1, text: Localization.text("chat.system.friendshipAcceptedOther"), canDelete: true), edit: {})
    return view
}
#endif
