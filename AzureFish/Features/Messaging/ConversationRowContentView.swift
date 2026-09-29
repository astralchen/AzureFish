import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

struct ConversationRowConfiguration: UIContentConfiguration {
    let row: LiveChatRow
    let session: SessionCoordinator

    func makeContentView() -> UIView & UIContentView {
        ConversationRowContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> Self { self }
}

/// 将名称与时间排在首行，摘要与未读状态排在次行，方向跟随会话列表。
final class ConversationRowContentView: QuickLayoutContentView {
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    let timeLabel = UILabel()
    private let avatar = AccountAvatarView()
    private let symbol = UIImageView()
    private let muted = UIImageView(image: UIImage(systemName: "bell.slash.fill"))
    private var badge: UnreadCountBadgeView?
    private var isMuted = false
    private var hasUserAvatar = false

    override init(configuration: UIContentConfiguration) {
        super.init(configuration: configuration)
        for label in [titleLabel, subtitleLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .natural
            label.isAccessibilityElement = false
        }
        titleLabel.numberOfLines = 0
        subtitleLabel.numberOfLines = 2
        timeLabel.numberOfLines = 1
        timeLabel.adjustsFontSizeToFitWidth = true
        timeLabel.minimumScaleFactor = 0.5
        titleLabel.textColor = .label
        subtitleLabel.textColor = .secondaryLabel
        timeLabel.textColor = .secondaryLabel
        avatar.tintColor = .systemBlue
        avatar.isAccessibilityElement = false
        symbol.tintColor = .systemBlue
        symbol.contentMode = .scaleAspectFit
        symbol.isAccessibilityElement = false
        muted.tintColor = .secondaryLabel
        muted.contentMode = .scaleAspectFit
        muted.isAccessibilityElement = false
        applyCurrentContentConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var body: Layout {
        HStack(alignment: .top, spacing: 12) {
            if hasUserAvatar { avatar.resizable().frame(width: 44, height: 44) }
            else { symbol.resizable().frame(width: 44, height: 44) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    titleLabel.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                    if timeLabel.text?.isEmpty == false {
                        timeLabel.frame(maxWidth: 120, alignment: .trailing)
                            .padding(.top, max(0, (titleLabel.font.lineHeight - timeLabel.font.lineHeight) / 2))
                            .layoutPriority(1)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    subtitleLabel.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                    if isMuted { muted.resizable().frame(width: 14, height: 14).padding(.top, 2) }
                    if let badge { badge.frame(width: badge.bounds.width, height: badge.bounds.height) }
                }
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    override func applyContentConfiguration(_ configuration: UIContentConfiguration) {
        guard let configuration = configuration as? ConversationRowConfiguration else { return }
        let row = configuration.row
        titleLabel.text = row.title
        subtitleLabel.attributedText = nil
        subtitleLabel.text = row.subtitle
        timeLabel.text = row.timeText
        timeLabel.accessibilityIdentifier = "chat.row.time." + row.id
        titleLabel.font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
        timeLabel.font = .preferredFont(forTextStyle: .caption1, compatibleWith: traitCollection)
        if row.isDraft {
            let text = NSMutableAttributedString(string: row.subtitle)
            if let range = row.subtitle.range(of: Localization.text("chat.list.draftMarker")) {
                text.addAttribute(.foregroundColor, value: UIColor.systemRed, range: NSRange(range, in: row.subtitle))
            }
            subtitleLabel.attributedText = text
        }
        if let user = row.avatarUser.flatMap(UUID.init(uuidString:)) {
            hasUserAvatar = true
            avatar.configure(session: configuration.session, user: user, asset: row.avatarAsset)
        } else {
            hasUserAvatar = false
            avatar.reset()
            symbol.image = UIImage(systemName: row.symbol)
        }
        isMuted = row.markers.contains("bell.slash.fill")
        badge = !row.badge.isEmpty || row.manuallyUnread ? UnreadCountBadgeView(text: row.badge, dot: row.badge.isEmpty) : nil
        super.applyContentConfiguration(configuration)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            applyCurrentContentConfiguration()
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("会话 · 名称与时间对齐") {
    ConversationRowContentView(configuration: ConversationRowConfiguration(
        row: LiveChatRow(id: "preview", title: "林沐", subtitle: "我们周末海边见", badge: "3", timeText: "20:10"),
        session: .configured()))
}
#endif
