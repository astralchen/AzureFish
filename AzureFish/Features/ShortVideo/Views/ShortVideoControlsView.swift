import AppLocalization
import AzureFishAPI
import QuickLayout
import QuickLayoutKit
import UIKit

/// 视频浮层只展示观看与互动入口；空白区域将点击和滑动交还分页列表。
final class ShortVideoControlsView: QuickLayoutView {
    private let author = UILabel(), tags = UILabel(), heading = UILabel()
    private let underline = UIView()
    let play = UIButton(type: .system), mute = UIButton(type: .system), like = UIButton(type: .system)
    let comments = UIButton(type: .system), share = UIButton(type: .system), source = UIButton(type: .system)
    let back = UIButton(type: .system), more = UIButton(type: .system)
    let seek = UISlider()
    private let scrim = CAGradientLayer()
    private var transparencyObserver: (any NSObjectProtocol)?
    private var compact = false, showsBack = false
    private var item: ShortVideoItem?
    private var paused = false, muted = true, mutating = false, ready = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        for label in [author, tags, heading] {
            label.textColor = .white; label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.layer.shadowColor = UIColor.black.cgColor; label.layer.shadowOpacity = 0.65
            label.layer.shadowRadius = 3; label.layer.shadowOffset = .init(width: 0, height: 1)
        }
        author.numberOfLines = 1; heading.numberOfLines = 1; heading.textAlignment = .center
        heading.accessibilityTraits = .header
        underline.backgroundColor = .white; underline.layer.cornerRadius = 1.5
        for button in [play, mute, like, comments, share, source, back, more] {
            button.tintColor = .white
            button.layer.shadowColor = UIColor.black.cgColor; button.layer.shadowOpacity = 0.5
            button.layer.shadowRadius = 3; button.layer.shadowOffset = .init(width: 0, height: 1)
        }
        source.contentHorizontalAlignment = .leading
        source.titleLabel?.adjustsFontForContentSizeCategory = true
        source.titleLabel?.numberOfLines = 1
        source.accessibilityIdentifier = "shortVideo.source"
        play.setPreferredSymbolConfiguration(.init(pointSize: 40, weight: .regular), forImageIn: .normal)
        play.alpha = 0.75
        more.showsMenuAsPrimaryAction = true
        more.accessibilityIdentifier = "shortVideo.more"
        back.accessibilityIdentifier = "shortVideo.back"
        seek.tintColor = UIColor.white.withAlphaComponent(0.8)
        seek.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        seek.setThumbImage(UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 5)), for: .normal)
        seek.setThumbImage(UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)), for: .highlighted)
        seek.accessibilityIdentifier = "shortVideo.progress"
        updateScrim()
        transparencyObserver = NotificationCenter.default.addObserver(forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateScrim() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        ZStack {
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 5) {
                        heading.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                        underline.frame(width: 22, height: 3)
                    }.frame(width: max(40, min(160, bounds.width - safeAreaInsets.left - safeAreaInsets.right - 200)))
                    HStack(spacing: 0) {
                        if showsBack { back.resizable().frame(width: 44, height: 44) }
                        Spacer()
                        mute.resizable().frame(width: 44, height: 44)
                        more.resizable().frame(width: 44, height: 44)
                    }
                }.frame(height: 48).padding(.horizontal, 12)
                    // 宽窗口隐藏导航栏后，顶部仍需为系统窗口按钮保留一行；仅移动控制区，不缩小视频画布。
                    .padding(.top, traitCollection.horizontalSizeClass == .regular ? max(0, 44 - safeAreaInsets.top) : 0)
                Spacer()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        author.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                        tags.resizable(axis: .horizontal).frame(maxWidth: .infinity)
                        source.resizable().frame(height: 44).frame(maxWidth: .infinity)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: compact ? 8 : 18) {
                        like.resizable().frame(width: 52, height: 58)
                        comments.resizable().frame(width: 52, height: 58)
                        share.resizable().frame(width: 52, height: 58)
                    }.padding(.bottom, 12)
                }.padding(.horizontal, 12)
                seek.resizable().frame(height: 44).padding(.horizontal, 8)
            }.safeAreaPadding(.all, 0)
            play.resizable().frame(width: 76, height: 76)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // 视频和渐变共用画布；QuickLayout 更新子视图顺序后，渐变仍置于控件下方。
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.insertSublayer(scrim, at: 0); scrim.frame = bounds
        CATransaction.commit()
        let next = bounds.height < 500
        if next != compact { compact = next; refreshButtons(); setNeedsQuickLayout() }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = super.hitTest(point, with: event) else { return nil }
        var candidate: UIView? = target
        while let view = candidate, view !== self {
            // 中央按钮仍可由 VoiceOver 操作，普通触摸交给列表的点击与翻页手势。
            if view === play { return nil }
            if view is UIControl { return target }
            candidate = view.superview
        }
        return nil
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateScrim(); refreshButtons(); setNeedsQuickLayout()
    }
    private func updateScrim() {
        let strong = UIAccessibility.isReduceTransparencyEnabled || UIAccessibility.isDarkerSystemColorsEnabled
        scrim.colors = [UIColor.black.withAlphaComponent(strong ? 0.85 : 0.5).cgColor,
                        UIColor.clear.cgColor, UIColor.clear.cgColor,
                        UIColor.black.withAlphaComponent(strong ? 1 : 0.75).cgColor]
        scrim.locations = [0, 0.2, 0.55, 1]
    }
    private func overlayFont(_ style: UIFont.TextStyle, size: CGFloat, maximum: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight),
            maximumPointSize: maximum, compatibleWith: traitCollection)
    }
    func configureHeader(showsBack: Bool, menu: UIMenu) {
        self.showsBack = showsBack; more.menu = menu; refreshButtons(); setNeedsQuickLayout()
    }
    func render(item: ShortVideoItem?, paused: Bool, muted: Bool, mutating: Bool, ready: Bool) {
        let becameLiked = self.item?.id == item?.id && self.item?.liked == false && item?.liked == true
        self.item = item; self.paused = paused; self.muted = muted; self.mutating = mutating; self.ready = ready
        author.text = item.map { "@" + $0.author }; tags.text = item?.tags
        for view in [author, tags, source] as [UIView] { view.isHidden = item == nil }
        source.setTitle("Pixabay ↗", for: .normal)
        source.accessibilityLabel = Localization.text("shortVideo.source")
        refreshButtons(); setNeedsQuickLayout()
        // 仅在服务端确认后给出点赞反馈；降低动态效果时保持静态状态切换。
        if becameLiked && !UIAccessibility.isReduceMotionEnabled {
            like.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) { self.like.transform = .identity }
        }
    }
    private func action(_ button: UIButton, symbol: String, title: String?, color: UIColor = .white, size: CGFloat = 28) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = .init(pointSize: size, weight: .medium)
        config.imagePlacement = .top; config.imagePadding = 3
        config.title = title; config.baseForegroundColor = color; config.contentInsets = .zero
        let font = overlayFont(.caption2, size: 11, maximum: 16, weight: .medium)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var result = incoming; result.font = font; return result
        }
        button.configuration = config
    }
    private func refreshButtons() {
        author.font = overlayFont(.headline, size: 17, maximum: 26, weight: .semibold)
        tags.font = overlayFont(.subheadline, size: 15, maximum: 22)
        heading.font = overlayFont(.headline, size: 17, maximum: 22, weight: .semibold)
        heading.text = Localization.text("shortVideo.popular")
        source.titleLabel?.font = overlayFont(.caption1, size: 12, maximum: 18)
        source.setTitleColor(UIColor.white.withAlphaComponent(0.85), for: .normal)
        let likeCount = item.map { $0.likeCount.formatted(.number.locale(Localization.localizationController.locale)) }
        let commentCount = item.map { $0.commentCount.formatted(.number.locale(Localization.localizationController.locale)) }
        let compactLike = item.map { $0.likeCount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Localization.localizationController.locale)) }
        let compactComments = item.map { $0.commentCount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Localization.localizationController.locale)) }
        action(like, symbol: "heart.fill", title: compactLike, color: item?.liked == true ? .systemPink : .white)
        action(comments, symbol: "ellipsis.bubble.fill", title: compactComments)
        // 辅助功能字号优先保证动作区域完整，完整名称仍由 accessibilityLabel 提供。
        action(share, symbol: "arrowshape.turn.up.right.fill", title: traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? nil : Localization.text("shortVideo.shareShort"))
        action(mute, symbol: muted ? "speaker.slash" : "speaker.wave.2", title: nil, size: 19)
        action(more, symbol: "ellipsis", title: nil, size: 22)
        action(back, symbol: "chevron.backward", title: nil, size: 22)
        more.accessibilityLabel = Localization.text("shortVideo.moreOptions")
        back.accessibilityLabel = Localization.text("shortVideo.back")
        play.setImage(paused ? UIImage(systemName: "play.fill") : nil, for: .normal)
        for (button, id, key) in [(play, "play", paused ? "play" : "pause"), (mute, "mute", muted ? "unmute" : "mute"),
                                  (like, "like", item?.liked == true ? "unlike" : "like"), (comments, "comments", "comments"), (share, "share", "share")] {
            button.accessibilityLabel = Localization.text("shortVideo." + key)
            button.accessibilityIdentifier = "shortVideo." + id
            button.isEnabled = item != nil
        }
        like.isEnabled = item != nil && !mutating
        like.accessibilityValue = likeCount; comments.accessibilityValue = commentCount
        like.accessibilityHint = Localization.text("shortVideo.countsNote")
        comments.accessibilityHint = Localization.text("shortVideo.countsNote")
        seek.isEnabled = ready; seek.accessibilityLabel = Localization.text("shortVideo.progress")
    }
    isolated deinit { if let transparencyObserver { NotificationCenter.default.removeObserver(transparencyObserver) } }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频观看浮层") {
    let view = ShortVideoControlsView()
    view.configureHeader(showsBack: false, menu: UIMenu())
    view.render(item: .init(id: "pixabay:1", author: "Sample creator", tags: "Nature · Mountains", sourceURL: "", videoURL: "", thumbnailURL: "", bytes: 1, duration: 12, width: 720, height: 1280), paused: true, muted: true, mutating: false, ready: true)
    return view
}
#endif
