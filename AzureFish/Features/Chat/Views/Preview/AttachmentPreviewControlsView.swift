import UIKit
import QuickLayout
import QuickLayoutKit

/// 附件预览控制层，拥有标题、菜单入口、播放条和缩略图；不持有播放器或分页控制器。
@available(iOS 26.0, *)
final class AttachmentPreviewControlsView: QuickLayoutView {
    let livePhotoButton = LivePhotoBadgeButton(frame: .zero)
    var didSelectLivePhotoMode: ((LivePhotoPlaybackMode) -> Void)?
    private var livePhotoMode: LivePhotoPlaybackMode = .live
    private var photoRect: CGRect = .zero

    /// 关闭预览的用户请求；宿主负责转场及清理。
    var didRequestClose: (() -> Void)?
    /// 播放或暂停的用户请求，不在视图内部准备播放器。
    var didRequestPlaybackToggle: (() -> Void)?
    /// 切换静音的用户请求。
    var didRequestMuteToggle: (() -> Void)?
    /// 进度拖动开始，宿主保存原播放状态。
    var didBeginSeeking: (() -> Void)?
    /// 连续进度请求及是否仍在触摸跟踪，兼容 VoiceOver 无按下／松手事件的调整。
    var didChangeSeekPosition: ((Double, Bool) -> Void)?
    /// 松手或取消后的最终进度，宿主处理异步定位与恢复播放。
    var didEndSeeking: ((Double) -> Void)?
    /// 控件恢复前请求宿主同步当前分页进度，避免显示旧的缩略图选择。
    var willRevealControls: (() -> Void)?
    /// 显隐或拖动形态变化后通知宿主刷新状态栏。
    var didChangeVisibility: (() -> Void)?
    /// 同一控制层持有一个缩略图条，分页与拖动回调由宿主协调。
    let thumbnailStrip: AttachmentThumbnailStripView
    /// 附件数量只决定控制层布局，不参与分页状态计算。
    private let itemCount: Int
    /// 用户选择的沉浸显隐状态，临时进度拖动不会改写它。
    private(set) var controlsVisible = true
    /// 缓存界面方向，避免周期布局重复配置返回图标。
    private var headerDirection: UIUserInterfaceLayoutDirection?
    /// 状态栏跟随整体显隐和拖动形态，VoiceOver 保留控制层。
    var prefersStatusBarHidden: Bool { !controlsVisible || (isScrubbingPresentation && !UIAccessibility.isVoiceOverRunning) }

    /// 玻璃合成容器只承载控制层，不参与主图布局。
    private lazy var glassContainer = QuickLayoutVisualEffectView(effect: UIGlassContainerEffect()) { [unowned self] in
        VStack(spacing: 0) {
            ZStack {
                titleView.resizable().frame(width: titleWidth, height: titleView.preferredHeight)
                HStack(spacing: 0) {
                    closeButton.resizable().frame(width: 44, height: 44)
                    Spacer()
                    moreButton.resizable().frame(width: 44, height: 44)
                }
            }.frame(height: titleView.preferredHeight)
            Spacer()
            if bottomHeight > 0 {
                VStack(spacing: 0) {
                    if isPlayable { playbackControls.resizable().frame(height: playbackControls.preferredHeight).padding(.horizontal, 12) }
                    if itemCount > 1 {
                        if isPlayable { Spacer().frame(height: 4) }
                        thumbnailStrip.resizable().frame(height: AttachmentThumbnailStripView.preferredHeight)
                    }
                }.frame(width: min(560, max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right - 32)), height: bottomHeight)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
        .safeAreaPadding(.all, 0)
    }
    /// 标题视图独立管理文本和内容尺寸。
    private let titleView = AttachmentPreviewTitleView()
    /// 播放控件独立管理子控件、时间和轨道，不向控制器暴露内部样式。
    let playbackControls = AttachmentPlaybackControlsView()
    /// 拖动形态只由触摸生命周期控制，播放器的异步 seek 回调不能重新展开面板。
    private(set) var isScrubbingPresentation = false
    /// 标题区域宽度为两侧按钮和间隔保留空间。
    private var titleWidth: CGFloat {
        titleView.preferredWidth(available: bounds.width - safeAreaInsets.left - safeAreaInsets.right - 32 - 120)
    }
    /// 与玻璃标题共享尺寸，避免依赖嵌套宿主完成布局的先后顺序。
    var documentTopInset: CGFloat { safeAreaInsets.top + 20 + titleView.preferredHeight }
    /// 当前附件是否需要显示媒体控件。
    private var isPlayable = false
    /// 底部控件与缩略图组合高度，保持已校准的间距。
    private var bottomHeight: CGFloat { (isPlayable ? playbackControls.preferredHeight : 0) + (itemCount > 1 ? AttachmentThumbnailStripView.preferredHeight + (isPlayable ? 4 : 0) : 0) }
    /// 返回按钮保持稳定实例，供转场完成后恢复辅助功能焦点。
    let closeButton = UIButton(type: .system)
    /// 菜单入口只显示宿主提供的已有操作。
    private let moreButton = UIButton(type: .system)

    /// 安装固定视图层级和事件回调，所有回调由宿主以弱引用连接。
    init(items: [AttachmentPreviewItem], selectedIndex: Int, imageLoader: MediaImageLoader? = nil) {
        itemCount = items.count
        thumbnailStrip = AttachmentThumbnailStripView(items: items, selectedIndex: selectedIndex, imageLoader: imageLoader)
        super.init(frame: .zero)
        addSubview(livePhotoButton)
        livePhotoButton.isHidden = true
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: AttachmentPreviewControlsView, _: UITraitCollection) in
            view.livePhotoButton.update(mode: view.livePhotoMode) { [weak view] mode in
                view?.didSelectLivePhotoMode?(mode)
            }
            view.setNeedsLayout()
        }
        configureButton(closeButton, symbol: "chevron.backward", key: "imessage.media.close", identifier: "imessage.media.preview.close")
        closeButton.configuration?.baseForegroundColor = .label
        configureButton(moreButton, symbol: "ellipsis", key: "imessage.preview.more", identifier: "imessage.preview.more")
        moreButton.configuration?.baseForegroundColor = .label
        moreButton.showsMenuAsPrimaryAction = true
        closeButton.addAction(UIAction { [weak self] _ in self?.didRequestClose?() }, for: .touchUpInside)
        playbackControls.didRequestPlaybackToggle = { [weak self] in self?.didRequestPlaybackToggle?() }
        playbackControls.didRequestMuteToggle = { [weak self] in self?.didRequestMuteToggle?() }
        playbackControls.didBeginSeeking = { [weak self] in
            guard let self else { return }
            didBeginSeeking?()
            setScrubbingPresentation(true)
        }
        playbackControls.didChangeSeekPosition = { [weak self] fraction, tracking in self?.didChangeSeekPosition?(fraction, tracking) }
        playbackControls.didEndSeeking = { [weak self] fraction in
            guard let self else { return }
            setScrubbingPresentation(false)
            didEndSeeking?(fraction)
        }

    }
    /// 控制层仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 透明控制层覆盖主图，不为主图保留额外布局空间。
    override var body: Layout { glassContainer.resizable() }

    /// 仅实际控件和滚动区域命中，透明空白继续交给主图。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        var ancestor = hit
        while let view = ancestor, view !== self {
            if view is UIControl || view is UIScrollView { return hit }
            ancestor = view.superview
        }
        return nil
    }

    /// 独立处理方向和嵌套玻璃布局，不要求宿主访问内部视图。
    override func layoutSubviews() {
        super.layoutSubviews()
        glassContainer.semanticContentAttribute = semanticContentAttribute
        let direction = effectiveUserInterfaceLayoutDirection
        if headerDirection != direction {
            headerDirection = direction
            closeButton.configuration?.image = UIImage(systemName: direction == .rightToLeft ? "chevron.right" : "chevron.left")
        }
        glassContainer.setNeedsQuickLayout()
        glassContainer.layoutIfNeeded()
        titleView.layoutIfNeeded()
        playbackControls.layoutIfNeeded()
        layoutLivePhotoBadge()
    }

    func updateLivePhoto(isLivePhoto: Bool, mode: LivePhotoPlaybackMode) {
        livePhotoMode = mode
        livePhotoButton.isHidden = !isLivePhoto
        livePhotoButton.update(mode: mode) { [weak self] value in self?.didSelectLivePhotoMode?(value) }
        setNeedsLayout()
    }

    func updatePhotoRect(_ rect: CGRect) {
        guard photoRect != rect else { return }
        photoRect = rect
        setNeedsLayout()
    }

    private func layoutLivePhotoBadge() {
        guard !livePhotoButton.isHidden else { return }
        livePhotoButton.semanticContentAttribute = semanticContentAttribute
        let photo = photoRect.isEmpty ? bounds : photoRect
        let leading = max(safeAreaInsets.left, photo.minX) + 16
        let trailing = min(bounds.width - safeAreaInsets.right, photo.maxX) - 16
        let available = max(0, trailing - leading)
        let size = livePhotoButton.sizeThatFits(CGSize(width: available, height: 100))
        let width = min(size.width, available)
        let top = max(documentTopInset, photo.minY + 6)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        livePhotoButton.frame = CGRect(x: rtl ? trailing - width : leading,
            y: top, width: width, height: max(20, size.height))
        bringSubviewToFront(livePhotoButton)
    }

    /// 同步正式选中项的信息与可播放性，不改变沉浸显隐状态。
    func updateItem(title: String, position: String, isPlayable: Bool) {
        titleView.update(title: title, position: position)
        self.isPlayable = isPlayable
        invalidateContentLayout()
    }

    /// 文档页码改变时只更新标题区域，保持播放与分页状态不变。
    func updatePosition(_ position: String) {
        titleView.updatePosition(position)
        invalidateContentLayout()
    }

    /// 菜单动作由宿主创建，控制层只负责显示已有业务操作。
    func updateMenu(_ menu: UIMenu) { moreButton.menu = menu }

    /// 让信息和可播放性变化重新参与嵌套布局测量。
    private func invalidateContentLayout() {
        glassContainer.setNeedsQuickLayout()
        titleView.setNeedsQuickLayout()
        playbackControls.setNeedsLayout()
        setNeedsQuickLayout()
    }

    /// 返回和菜单共用系统玻璃按钮样式及原辅助功能标识。
    private func configureButton(_ button: UIButton, symbol: String, key: String, identifier: String) {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: symbol)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        button.configuration = config
        button.accessibilityLabel = Localization.text(key)
        button.accessibilityIdentifier = identifier
    }
    /// 转发播放器快照，播放控件独立更新按钮、进度和时间文案。
    func updatePlayback(time: Double, duration: Double, isPlaying: Bool, isMuted: Bool, isSeeking: Bool) {
        playbackControls.updatePlayback(time: time, duration: duration, isPlaying: isPlaying, isMuted: isMuted, isSeeking: isSeeking)
    }
    /// 展开与收起从当前动画状态衔接；只暂隐其他控制，不改写用户的沉浸显隐状态。
    private func setScrubbingPresentation(_ expanded: Bool) {
        guard isScrubbingPresentation != expanded else { return }
        layoutIfNeeded()
        isScrubbingPresentation = expanded
        let hidesSurroundingControls = expanded && !UIAccessibility.isVoiceOverRunning
        for control in [titleView, closeButton, moreButton, thumbnailStrip, livePhotoButton] {
            control.isUserInteractionEnabled = !hidesSurroundingControls
            control.accessibilityElementsHidden = hidesSurroundingControls
        }
        thumbnailStrip.setContentActive(controlsVisible && !hidesSurroundingControls)
        if !expanded { willRevealControls?() }
        playbackControls.setNeedsLayout()
        glassContainer.setNeedsQuickLayout()
        setNeedsQuickLayout()
        playbackControls.prepareExpansion(expanded)
        let changes = {
            self.layoutIfNeeded()
            self.playbackControls.applyExpansionAppearance()
            for control in [self.titleView, self.closeButton, self.moreButton, self.thumbnailStrip, self.livePhotoButton] {
                control.alpha = hidesSurroundingControls ? 0 : 1
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(changes)
        } else {
            UIView.animate(withDuration: 0.22, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut], animations: changes)
        }
        didChangeVisibility?()
    }
    /// 控制层只覆盖内容；隐藏不改变主图几何，也不在翻页或加载完成时自动显示。
    func toggleControls() {
        guard !UIAccessibility.isVoiceOverRunning, !isScrubbingPresentation else { return }
        controlsVisible.toggle()
        willRevealControls?()
        thumbnailStrip.setContentActive(controlsVisible)
        self.isUserInteractionEnabled = controlsVisible
        self.accessibilityElementsHidden = !controlsVisible
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.22,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = self.controlsVisible ? 1 : 0
        }
        didChangeVisibility?()
    }
    /// 环境设置仅影响材质和可访问性，VoiceOver 开启时恢复控制层。
    func applyAccessibilitySettings() {
        livePhotoButton.update(mode: livePhotoMode) { [weak self] value in self?.didSelectLivePhotoMode?(value) }
        titleView.applyAccessibilitySettings()
        playbackControls.applyAccessibilitySettings()
        if UIAccessibility.isVoiceOverRunning {
            controlsVisible = true
            willRevealControls?()
            thumbnailStrip.setContentActive(true)
            self.alpha = 1
            self.isUserInteractionEnabled = true
            self.accessibilityElementsHidden = false
            didChangeVisibility?()
        }
    }
}
