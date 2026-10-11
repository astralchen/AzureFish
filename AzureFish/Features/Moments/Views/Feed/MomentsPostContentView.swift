import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 动态行的展示输入及用户动作回调；width 为列表内容容器宽度，单位为点。
struct MomentsPostConfiguration: UIContentConfiguration {
    let post: MomentsPost
    let media: MomentsMediaProvider
    let width: CGFloat
    let expanded: Bool
    let action: (MomentsAction) -> Void
    func makeContentView() -> UIView & UIContentView { MomentsPostContentView(configuration: self) }
    func updated(for state: UIConfigurationState) -> Self { self }
}
/// 自适应动态内容；按钮保留独立无障碍元素，图片不随 RTL 镜像。
final class MomentsPostContentView: QuickLayoutContentView {
    private let avatar = AccountAvatarView()
    private let name = UIButton(type: .system)
    private let text = UILabel()
    private let time = UILabel()
    private let expand = UIButton(type: .system)
    private let like = UIButton(type: .system)
    private let comment = UIButton(type: .system)
    private let menu = UIButton(type: .system)
    private let likedBy = UILabel()
    private var replies: [UIButton] = []
    private var pictures: [UIButton] = []
    private var imageBindings: [MomentsImageBinding] = []
    private var photoSize = CGSize(width: 80, height: 80)
    private var photoColumns = 3
    private var showExpand = false
    private let videoBadge = UILabel()
    private let videoPlayIcon = UIImageView(image: UIImage(systemName: "play.circle.fill"))
    private var isVideo = false
    override init(configuration: UIContentConfiguration) {
        super.init(configuration: configuration)
        for label in [text, time, likedBy] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        text.font = .preferredFont(forTextStyle: .body); time.font = .preferredFont(forTextStyle: .caption1)
        likedBy.font = .preferredFont(forTextStyle: .subheadline); time.textColor = .secondaryLabel; likedBy.textColor = .secondaryLabel
        name.contentHorizontalAlignment = .leading
        name.titleLabel?.font = .preferredFont(forTextStyle: .headline); name.titleLabel?.numberOfLines = 0
        name.titleLabel?.adjustsFontForContentSizeCategory = true
        for button in [expand, like, comment, menu] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .regular), forImageIn: .normal)
        }
        videoBadge.textColor = .white; videoBadge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        videoBadge.font = .preferredFont(forTextStyle: .caption1); videoBadge.isUserInteractionEnabled = false
        videoBadge.isAccessibilityElement = false
        videoPlayIcon.tintColor = .white; videoPlayIcon.contentMode = .scaleAspectFit; videoPlayIcon.isUserInteractionEnabled = false
        applyCurrentContentConfiguration()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(alignment: .top, spacing: 12) {
            avatar.resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 8) {
                name.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 44)
                if text.text?.isEmpty == false { text.resizable(axis: .horizontal).frame(maxWidth: .infinity) }
                if showExpand { expand.frame(minHeight: 44) }
                if !pictures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        for start in stride(from: 0, to: pictures.count, by: photoColumns) {
                            HStack(spacing: 4) {
                                ForEach(Array(pictures[start..<min(start + photoColumns, pictures.count)])) { button in
                                    ZStack {
                                        button.resizable().frame(width: photoSize.width, height: photoSize.height)
                                        if isVideo {
                                            videoPlayIcon.frame(width: 40, height: 40)
                                            VStack { Spacer(); HStack { Spacer(); videoBadge.padding(6) }.frame(maxWidth: .infinity) }
                                                .frame(width: photoSize.width, height: photoSize.height)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                time.resizable(axis: .horizontal)
                if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                    VStack(alignment: .leading, spacing: 4) { like.frame(minHeight: 44); comment.frame(minHeight: 44); menu.frame(minWidth: 44, minHeight: 44) }
                } else {
                    HStack(spacing: 12) { like.frame(minHeight: 44); comment.frame(minHeight: 44); menu.frame(minWidth: 44, minHeight: 44) }
                }
                if likedBy.text?.isEmpty == false { likedBy.resizable(axis: .horizontal).frame(maxWidth: .infinity).padding(10) }
                ForEach(replies) { $0.resizable(axis: .horizontal).frame(maxWidth: .infinity, minHeight: 44) }
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 16).padding(.vertical, 16)
    }
    /// 配置文字、互动与媒体布局；复用图片按钮和绑定，避免状态刷新时重复加载。
    override func applyContentConfiguration(_ configuration: UIContentConfiguration) {
        guard let config = configuration as? MomentsPostConfiguration else { return }
        let post = config.post
        let media = post.video.map { [$0] } ?? post.images
        isVideo = post.video != nil
        if let video = post.video {
            let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.minute, .second]; formatter.zeroFormattingBehavior = .pad
            videoBadge.text = (formatter.string(from: Double(video.duration) / 1000) ?? "")
        }
        let availableWidth = max(1, config.width - 84)
        // 多图保持统一缩略图尺寸，宽窗口也不放大到整个正文栏。
        let edge = max(1, floor((min(320, availableWidth) - 8) / 3))
        photoColumns = media.count == 4 ? 2 : 3
        photoSize = CGSize(width: edge, height: edge)
        if media.count == 1, let asset = media.first {
            let ratio = asset.width > 0 && asset.height > 0 ? CGFloat(asset.width) / CGFloat(asset.height) : 1
            let width = min(280, availableWidth, 360 * ratio)
            photoSize = CGSize(width: width, height: width / ratio)
        }
        text.text = post.text; text.numberOfLines = config.expanded ? 0 : 6
        let textWidth = max(1, config.width - 84)
        let fullHeight = (post.text as NSString).boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: text.font!], context: nil).height
        showExpand = fullHeight > text.font.lineHeight * 6
        name.setTitle(post.author.nickname, for: .normal)
        replace(name, id: "author") { config.action(.author) }
        config.media.configure(avatar, user: post.author)
        expand.setTitle(Localization.text(config.expanded ? "moments.collapse" : "moments.expand"), for: .normal)
        replace(expand, id: "expand") { config.action(.expand) }
        let liked = post.likes.contains { $0.id == config.media.userID }
        like.setTitle(Localization.text(liked ? "moments.unlike" : "moments.like"), for: .normal)
        like.setImage(UIImage(systemName: liked ? "heart.fill" : "heart"), for: .normal)
        like.accessibilityIdentifier = "moments.like." + post.id
        replace(like, id: "like") { config.action(.like) }
        comment.setTitle(Localization.text("moments.comment"), for: .normal)
        comment.accessibilityIdentifier = "moments.comment." + post.id
        replace(comment, id: "comment") { config.action(.comment) }
        menu.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        menu.accessibilityLabel = Localization.text("moments.actions")
        menu.accessibilityIdentifier = "moments.actions." + post.id
        menu.isHidden = post.author.id != config.media.userID
        menu.menu = UIMenu(children: [UIAction(title: Localization.text("moments.delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in config.action(.delete) }])
        menu.showsMenuAsPrimaryAction = true
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: Localization.localizationController.currentLocale.identifier)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        time.text = formatter.string(from: Date(timeIntervalSince1970: Double(post.createdAt) / 1000))
        let names = ListFormatter(); names.locale = formatter.locale
        likedBy.text = post.likes.isEmpty ? nil : Localization.text("moments.likedBy", names.string(from: post.likes.map(\.nickname)) ?? "")
        likedBy.backgroundColor = .secondarySystemBackground
        // UIKit 会在菜单、高亮等状态变化后再次应用配置，不能在这里重建图片视图。
        while pictures.count > media.count { pictures.removeLast(); imageBindings.removeLast() }
        while pictures.count < media.count {
            let button = UIButton(type: .custom); button.backgroundColor = .secondarySystemBackground
            button.imageView?.contentMode = .scaleAspectFill; button.clipsToBounds = true; button.layer.cornerRadius = 4
            pictures.append(button); imageBindings.append(MomentsImageBinding())
        }
        for (index, asset) in media.enumerated() {
            let button = pictures[index]
            button.accessibilityLabel = isVideo ? Localization.text("moments.videoPlay") + ", " + (videoBadge.text ?? "") : Localization.text("moments.photoNumber", Int64(index + 1))
            button.accessibilityIdentifier = "moments.photo.\(post.id).\(index)"
            replace(button, id: "photo") { config.action(.photo(index)) }
            config.media.bind(imageBindings[index], to: button, asset: asset, target: post.id)
        }
        replies = post.comments.map { value in
            let button = UIButton(type: .system)
            let title = value.replyTo.map { Localization.text("moments.replyLine", value.author.nickname, $0.nickname, value.text) }
                ?? Localization.text("moments.commentLine", value.author.nickname, value.text)
            button.setTitle(title, for: .normal); button.titleLabel?.numberOfLines = 0
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline); button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.contentHorizontalAlignment = .leading; button.backgroundColor = .secondarySystemBackground
            button.accessibilityIdentifier = "moments.reply." + value.id
            button.addAction(UIAction { _ in config.action(.reply(value)) }, for: .touchUpInside)
            if value.author.id == config.media.userID {
                button.menu = UIMenu(children: [UIAction(title: Localization.text("moments.deleteComment"), attributes: .destructive) { _ in config.action(.deleteComment(value)) }])
            }
            return button
        }
        setNeedsQuickLayout()
    }
    private func replace(_ button: UIButton, id: String, action: @escaping () -> Void) {
        let id = UIAction.Identifier(id); button.removeAction(identifiedBy: id, for: .touchUpInside)
        button.addAction(UIAction(identifier: id) { _ in action() }, for: .touchUpInside)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈动态") {
    let post = MomentsPreviewData.posts[0]
    return MomentsPostContentView(configuration: MomentsPostConfiguration(post: post, media: MomentsMediaProvider(runtime: MomentsPreviewData.runtime()), width: 390, expanded: false, action: { _ in }))
}
@available(iOS 17.0, *)
#Preview("单张横图") { MomentsPostContentView.preview(imageCount: 1) }
@available(iOS 17.0, *)
#Preview("单张竖图") { MomentsPostContentView.preview(imageCount: 1, portrait: true) }
@available(iOS 17.0, *)
#Preview("两张图片") { MomentsPostContentView.preview(imageCount: 2) }
@available(iOS 17.0, *)
#Preview("四张图片 · 2×2") { MomentsPostContentView.preview(imageCount: 4) }
@available(iOS 17.0, *)
#Preview("六张图片") { MomentsPostContentView.preview(imageCount: 6) }
@available(iOS 17.0, *)
#Preview("九张图片 · 宽容器") { MomentsPostContentView.preview(imageCount: 9, width: 720) }
private extension MomentsPostContentView {
    static func preview(imageCount: Int, portrait: Bool = false, width: CGFloat = 390) -> MomentsPostContentView {
        var post = MomentsPreviewData.posts[0]; post.images = Array(post.images.prefix(imageCount))
        if portrait { post.images[0].width = 120; post.images[0].height = 160 }
        return MomentsPostContentView(configuration: MomentsPostConfiguration(post: post, media: MomentsMediaProvider(runtime: MomentsPreviewData.runtime()), width: width, expanded: false, action: { _ in }))
    }
}
#endif
