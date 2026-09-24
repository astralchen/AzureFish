//
//  AttachmentCard.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 文件与链接附件卡片共用的字体和布局规格。
enum AttachmentCardStyle {
    /// 文件卡片缩略图的边长，单位为点。
    static let thumbnailSize: CGFloat = 60
    /// 文件缩略图的圆角半径，单位为点。
    static let thumbnailCornerRadius: CGFloat = 4
    /// 附件标题与详情文字之间的垂直间距，单位为点。
    static let textSpacing: CGFloat = 2
    /// 附件卡片内容的四周内边距，单位为点。
    static let contentInset: CGFloat = 12
    /// 缩略图与文字内容之间的间距，单位为点。
    static let iconTextSpacing: CGFloat = 12
    // 内容自身的右内边距也计入删除按钮的 44 pt 点击区域，避免重复留白。
    /// 扣除内容内边距后，删除按钮还需要额外保留的宽度。
    static let removeReservedWidth: CGFloat = 44 - contentInset

    /// 返回按指定特征集合缩放的附件标题字体。
    static func titleFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold), compatibleWith: traits
        )
    }

    /// 返回按指定特征集合缩放的附件详情字体。
    static func detailFont(for traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: 13), compatibleWith: traits
        )
    }
}

/// 链接按封面和图标内容测量，文件与单项媒体共用带独立删除区的附件卡片。
@available(iOS 17.0, *)
final class AttachmentCard: QuickLayoutView, UIGestureRecognizerDelegate {
    /// 显示文件图标或媒体缩略图的带边框视图。
    private let icon = AttachmentThumbnailView()
    /// 叠加在视频缩略图上的播放标记。
    private let playBadge = UIImageView()
    /// 显示文件名称或链接标题的多行标签。
    private let titleLabel = UILabel()
    /// 显示文件大小、导入状态或链接地址的详情标签。
    private let detailLabel = UILabel()
    /// 编辑器模式下删除当前草稿的按钮。
    private let removeButton = DraftRemoveButton(frame: .zero)
    /// 触发附件打开操作的轻点手势。
    private let openGesture = UITapGestureRecognizer()
    /// 使用缓存网页元数据的链接预览视图。
    private var linkView = LinkPreviewView()
    /// 最近一次测量的宽度约束与结果，用于判断内容更新是否改变尺寸。
    private var lastMeasurement: (width: CGFloat, size: CGSize)?
    /// 卡片首选尺寸确实变化时调用的闭包。
    var preferredSizeDidChange: (() -> Void)?
    /// 指示当前草稿是否采用链接卡片布局的布尔值。
    private var isLink = false
    /// 指示当前媒体缩略图是否需要视频播放标记的布尔值。
    private var isVideo = false
    /// 最近一次应用的草稿值，用于避免相同内容重复配置。
    private var configuredDraft: DocumentDraft?
    /// 发送气泡和 TextKit 附件共用测量，保留大封面与紧凑卡的差异。
    func preferredSize(maximumWidth: CGFloat) -> CGSize {
        let width = max(1, maximumWidth)
        let size: CGSize
        if isLink && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            let fitted = linkView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            size = CGSize(
                width: min(width, max(44, ceil(fitted.width.isFinite ? fitted.width : width))),
                height: max(44, ceil(fitted.height.isFinite ? fitted.height : 84))
            )
        } else {
            // 最大宽度只作为上限；短文件名不应把剩余空间留在文字右侧。
            let textWidth = max(0, titleLabel.intrinsicContentSize.width, detailLabel.intrinsicContentSize.width)
            let iconWidth = isLink ? 0 : AttachmentCardStyle.thumbnailSize
                + AttachmentCardStyle.iconTextSpacing
            let naturalWidth = ceil(textWidth + iconWidth
                + AttachmentCardStyle.contentInset * 2
                + (remove == nil ? 0 : AttachmentCardStyle.removeReservedWidth))
            size = CGSize(width: min(width, max(44, naturalWidth)),
                          height: TextAttachment.height(for: traitCollection))
        }
        lastMeasurement = (width, size)
        return size
    }

    /// 响应父布局分配的宽度，发送气泡与编辑器使用相同的内容测量规则。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        preferredSize(maximumWidth: size.width)
    }

    /// 按上次宽度重新测量链接卡片，仅在结果变化时通知布局更新。
    private func linkPreferredSizeDidChange() {
        guard let previous = lastMeasurement else { return }
        let size = preferredSize(maximumWidth: previous.width)
        guard size != previous.size else { return }
        setNeedsQuickLayout()
        invalidateIntrinsicContentSize()
        preferredSizeDidChange?()
    }
    /// 打开当前附件的回调；变化时重新生成辅助功能动作。
    var open: (() -> Void)? { didSet { refreshAccessibilityActions() } }
    /// 删除当前附件的回调；为 `nil` 时隐藏删除按钮并收回预留空间。
    var remove: (() -> Void)? {
        didSet {
            linkView.showsRemoveButton = remove != nil
            removeButton.isHidden = remove == nil
            removeButton.isEnabled = remove != nil
            refreshAccessibilityActions()
            setNeedsQuickLayout()
        }
    }

    /// 定义 `AttachmentCard` 的布局层级、间距和对齐方式。
    @LayoutBuilder override var body: Layout {
        if isLink && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            // 封面和文字背景覆盖整张卡片；删除按钮叠放，不添加异色侧栏。
            ZStack(alignment: effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .topLeading : .topTrailing) {
                linkView.resizable().frame(maxWidth: .infinity, maxHeight: .infinity)
                if remove != nil {
                    removeButton.resizable().frame(width: 44, height: 44)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 点击区与内容右内边距共用空间，文字仍停在点击区之外。
            ZStack(alignment: effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .topLeading : .topTrailing) {
                cardContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(effectiveUserInterfaceLayoutDirection == .rightToLeft ? .leading : .trailing,
                             remove == nil ? 0 : AttachmentCardStyle.removeReservedWidth)
                if remove != nil {
                    removeButton.resizable().frame(width: 44, height: 44)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 组织缩略图、标题和详情的标准文件卡片布局。
    @LayoutBuilder private var cardContent: Layout {
        HStack(alignment: .center, spacing: AttachmentCardStyle.iconTextSpacing) {
            if !isLink {
                ZStack {
                    icon.resizable().frame(
                        width: AttachmentCardStyle.thumbnailSize,
                        height: AttachmentCardStyle.thumbnailSize
                    )
                    if isVideo { playBadge.resizable().frame(width: 28, height: 28) }
                }
            }
            VStack(alignment: .leading, spacing: AttachmentCardStyle.textSpacing) {
                titleLabel.resizable(axis: .horizontal).fixedSize(axis: .vertical)
                detailLabel.resizable(axis: .horizontal).fixedSize(axis: .vertical)
            }
        }.padding(AttachmentCardStyle.contentInset)
    }

    /// 使用指定初始边框创建 `AttachmentCard`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .partial
        quickLayoutVerticalFlexibility = .fixedSize
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 20
        clipsToBounds = true
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        playBadge.image = UIImage(systemName: "play.circle.fill")?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(paletteColors: [.white, .black.withAlphaComponent(0.7)])
        )
        playBadge.contentMode = .scaleAspectFit
        titleLabel.numberOfLines = 2
        detailLabel.numberOfLines = 1
        detailLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontForContentSizeCategory = true
        // 20 点卡片圆角需要比照片缩略图更多留白，避免圆形按钮贴住弧线。
        // 文件卡片的删除入口采用固定物理右侧布局。
        removeButton.semanticContentAttribute = .forceLeftToRight
        removeButton.visualInset = 8
        removeButton.isHidden = true
        removeButton.isEnabled = false
        removeButton.accessibilityIdentifier = "imessage.attachment.remove"
        removeButton.addTarget(self, action: #selector(removeAttachment), for: .touchUpInside)
        // 卡片作为一个 VO 元素，移除通过自定义动作提供，避免重复朗读内部装饰。
        removeButton.isAccessibilityElement = false
        isAccessibilityElement = true
        openGesture.addTarget(self, action: #selector(openAttachment))
        openGesture.delegate = self
        addGestureRecognizer(openGesture)
        refreshAccessibilityActions()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (card: AttachmentCard, _: UITraitCollection) in
            if let draft = card.configuredDraft { card.configure(draft) }
            DispatchQueue.main.async { [weak card] in card?.linkPreferredSizeDidChange() }
        }
    }
    /// 不支持从归档创建 `AttachmentCard`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 按附件类型和导入状态配置卡片内容，保留相同草稿对应的已有视图。
    func configure(_ draft: DocumentDraft) {
        titleLabel.font = AttachmentCardStyle.titleFont(for: traitCollection)
        detailLabel.font = AttachmentCardStyle.detailFont(for: traitCollection)
        isLink = false
        isVideo = false
        icon.contentMode = .scaleAspectFit
        titleLabel.text = nil
        detailLabel.text = nil
        switch draft.attachment {
        case .mediaGroup, .file: break
        default: icon.setThumbnail(nil); icon.image = nil
        }
        switch draft.attachment {
        case .file(let file):
            titleLabel.text = file.displayName
            let type = UTType(file.typeIdentifier)
            let typeName = type?.conforms(to: .audio) == true
                ? Localization.text("imessage.audio.attachment.recording")
                : file.fileURL.pathExtension.uppercased()
            detailLabel.text = "\(typeName) · \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))"
            let symbol = type?.conforms(to: .audio) == true ? "music.note"
                : type?.conforms(to: .pdf) == true ? "doc.richtext" : "doc.text"
            icon.setThumbnail(file.thumbnailURL, placeholder: UIImage(systemName: symbol))
            accessibilityIdentifier = "imessage.attachment.file.card"
        case .link(let link):
            isLink = true
            if configuredDraft != draft {
                linkView = LinkPreviewView(link: link)
                linkView.showsRemoveButton = remove != nil
            }
            titleLabel.text = link.title ?? link.url.host ?? link.url.absoluteString
            detailLabel.text = link.url.path.isEmpty || link.url.path == "/" ? link.url.scheme?.uppercased() : link.url.path
            icon.image = UIImage(systemName: "link")
            accessibilityIdentifier = "imessage.attachment.link.card"
        case .mediaGroup(let group):
            accessibilityIdentifier = "imessage.attachment.media.card"
            if let media = group.items.first {
                isVideo = media.kind.isVideo
                icon.contentMode = .scaleAspectFill
                icon.setThumbnail(media.thumbnailFileURL)
                titleLabel.text = Localization.text(isVideo ? "imessage.media.video"
                    : media.showsAnimatedBadge ? "imessage.media.animatedImage" : "imessage.media.image")
                if let duration = media.kind.duration {
                    detailLabel.text = AudioBubbleView.durationText(duration)
                } else {
                    detailLabel.text = "\(Int(media.pixelSize.width)) × \(Int(media.pixelSize.height))"
                }
            } else {
                titleLabel.text = Localization.text("imessage.media.image")
                icon.image = UIImage(systemName: "photo")
            }
        case .audio(let audio):
            titleLabel.text = Localization.text("imessage.audio.attachment.recording")
            detailLabel.text = AudioBubbleView.durationText(audio.duration)
            icon.image = UIImage(systemName: "waveform")
            accessibilityIdentifier = "imessage.attachment.audio.card"
        }
        configuredDraft = draft
        if draft.status != .ready {
            detailLabel.text = Localization.text(draft.status == .importing
                ? "imessage.media.importing" : "imessage.attachment.importFailed")
        }
        titleLabel.textAlignment = .natural
        detailLabel.textAlignment = .natural
        accessibilityLabel = "\(titleLabel.text ?? ""), \(detailLabel.text ?? "")"
        if case .link(let link) = draft.attachment {
            accessibilityLabel = "\(link.title ?? ""), \(link.url.absoluteString)"
        }
        refreshAccessibilityActions()
        setNeedsQuickLayout()
    }

    /// 根据当前打开与删除回调重建可用的辅助功能动作。
    private func refreshAccessibilityActions() {
        let canOpen = configuredDraft?.status == .ready && open != nil
        openGesture.isEnabled = canOpen
        accessibilityTraits = canOpen ? .button : .staticText
        var actions: [UIAccessibilityCustomAction] = []
        if canOpen {
            actions.append(UIAccessibilityCustomAction(
                name: Localization.text("imessage.media.openPreview"), target: self, selector: #selector(accessibleOpen)
            ))
        }
        removeButton.accessibilityLabel = Localization.text("imessage.media.remove")
        if remove != nil {
            actions.append(UIAccessibilityCustomAction(
                name: Localization.text("imessage.media.remove"), target: self, selector: #selector(accessibleRemove)
            ))
        }
        accessibilityCustomActions = actions.isEmpty ? nil : actions
    }

    /// 按钮及其内部视图的整个 44pt 区域都不参与打开手势。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchedView = touch.view else { return false }
        return touchedView !== removeButton && !touchedView.isDescendant(of: removeButton)
    }

    /// 将轻点手势转交到统一附件打开动作。
    @objc private func openAttachment() { _ = accessibleOpen() }
    /// 将删除按钮事件转交到统一附件删除动作。
    @objc private func removeAttachment() { _ = accessibleRemove() }
    /// 通过辅助功能激活当前附件的打开操作。
    override func accessibilityActivate() -> Bool { accessibleOpen() }
    /// 执行附件打开回调；没有可用回调时返回 `false`。
    @objc private func accessibleOpen() -> Bool {
        guard configuredDraft?.status == .ready, let open else { return false }
        open()
        return true
    }
    /// 执行附件删除回调；没有可用回调时返回 `false`。
    @objc private func accessibleRemove() -> Bool {
        guard let remove else { return false }
        remove()
        return true
    }
}
