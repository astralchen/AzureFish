import UIKit

/// 自包含的媒体播放控件，负责按钮、精确时间、进度和两种形态；只通过回调请求播放操作。
@available(iOS 26.0, *)
final class AttachmentPlaybackControlsView: UIVisualEffectView {
    /// 播放按钮，保留稳定的辅助功能入口以支持宿主测试。
    let playButton = UIButton(type: .system)
    /// 两种形态共享的滑动控件，任何形态切换都不重新挂载。
    let slider = AttachmentPlaybackSlider(frame: .zero)
    /// 静音按钮只表达用户意图，不持有音频会话。
    private let muteButton = UIButton(type: .system)
    /// 左侧精确时间，拖动时直接显示目标位置。
    private let timeLabel = UILabel()
    /// 右侧总时长，保持与左侧文字同一基线。
    private let durationLabel = UILabel()
    /// 最近一次播放器时间快照，异步更新不会改变展开状态。
    private var playbackTime: Double = 0
    /// 最近一次播放器总时长。
    private var playbackDuration: Double = 0
    /// 外层控制视图统一协调形变及其他控件的显隐。
    private(set) var isExpanded = false
    /// 常态 48 pt，展开按时间字号增加高度。
    var preferredHeight: CGFloat { 48 + (isExpanded ? max(22, timeLabel.font.lineHeight + 4) : 0) }
    /// 播放／暂停请求，由宿主管理播放器。
    var didRequestPlaybackToggle: (() -> Void)?
    /// 静音请求，由宿主管理播放器。
    var didRequestMuteToggle: (() -> Void)?
    /// 触摸开始，先通知外层协调暂停和形态。
    var didBeginSeeking: (() -> Void)?
    /// 用户目标和触摸状态，支持无按下事件的辅助功能调整。
    var didChangeSeekPosition: ((Double, Bool) -> Void)?
    /// 松手或取消后的最终目标，异步提交由宿主处理。
    var didEndSeeking: ((Double) -> Void)?

    /// 安装持久子控件及样式，所有事件均通过弱引用闭包转发。
    init() {
        super.init(effect: UIGlassEffect(style: .clear))
        overrideUserInterfaceStyle = .dark
        clipsToBounds = true
        cornerConfiguration = .uniformCorners(radius: .fixed(24))
        accessibilityIdentifier = "imessage.preview.playback"
        playButton.accessibilityLabel = Localization.text("imessage.preview.play")
        playButton.accessibilityIdentifier = "imessage.preview.play"
        muteButton.accessibilityLabel = Localization.text("imessage.preview.mute")
        muteButton.accessibilityIdentifier = "imessage.preview.mute"
        configurePlaybackButton(playButton, symbol: "play.fill")
        configurePlaybackButton(muteButton, symbol: "speaker.wave.2.fill")
        slider.accessibilityLabel = Localization.text("imessage.preview.progress")
        slider.accessibilityIdentifier = "imessage.preview.progress"
        slider.semanticContentAttribute = .forceLeftToRight
        for label in [timeLabel, durationLabel] {
            label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold))
            label.adjustsFontForContentSizeCategory = true
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.textColor = .white
            label.alpha = 0
            label.accessibilityElementsHidden = true
        }
        timeLabel.textAlignment = .left
        durationLabel.textAlignment = .right
        timeLabel.accessibilityIdentifier = "imessage.preview.seek.time"
        durationLabel.accessibilityIdentifier = "imessage.preview.seek.duration"
        for view in [playButton, muteButton, slider, timeLabel, durationLabel] { contentView.addSubview(view) }
        playButton.addAction(UIAction { [weak self] _ in self?.didRequestPlaybackToggle?() }, for: .touchUpInside)
        muteButton.addAction(UIAction { [weak self] _ in self?.didRequestMuteToggle?() }, for: .touchUpInside)
        slider.addTarget(self, action: #selector(seekBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(seekEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    /// 播放控件仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// 轨道中心距底边 24 pt，时间中心距底边 46 pt，避免叠层测量产生居中偏移。
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let bottom = contentView.bounds.height
        playButton.frame = CGRect(x: 2, y: bottom - 46, width: 44, height: 44)
        muteButton.frame = CGRect(x: width - 46, y: bottom - 46, width: 44, height: 44)
        let inset: CGFloat = isExpanded ? 20 : 48
        slider.frame = CGRect(x: inset, y: bottom - 46, width: max(0, width - 2 * inset), height: 44)
        let rowHeight = max(22, timeLabel.font.lineHeight + 4)
        let labelWidth = max(0, (width - 48) / 2)
        timeLabel.frame = CGRect(x: 20, y: bottom - 46 - rowHeight / 2, width: labelWidth, height: rowHeight)
        durationLabel.frame = CGRect(x: width - 20 - labelWidth, y: timeLabel.frame.minY, width: labelWidth, height: rowHeight)
    }

    /// 原生符号按钮共享外层材质，只改变图标和按压反馈，保留辅助功能文案及 44 pt 命中区。
    private func configurePlaybackButton(_ button: UIButton, symbol: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = .zero
        button.configuration = configuration
    }
    /// 周期时间回调只更新控件，不重新连接视频图层的播放器。
    func updatePlayback(time: Double, duration: Double, isPlaying: Bool, isMuted: Bool, isSeeking: Bool) {
        playbackTime = time
        playbackDuration = duration
        playButton.configuration?.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        playButton.accessibilityLabel = Localization.text(isPlaying ? "imessage.preview.pause" : "imessage.preview.play")
        muteButton.configuration?.image = UIImage(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        muteButton.accessibilityLabel = Localization.text(isMuted ? "imessage.preview.unmute" : "imessage.preview.mute")
        if !isSeeking { slider.value = duration > 0 ? Float(time / duration) : 0 }
        slider.isEnabled = duration > 0
        updateSeekTime()
        slider.accessibilityValue = "\(Self.time(time)) / \(Self.time(duration))"
    }
    /// 辅助功能读数保留原分钟／秒格式，不暴露百分秒细节。
    private static func time(_ value: Double) -> String { let seconds = Int(max(0, value)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// 根据手指目标更新时间，不等待播放器解码完成，避免精确时间显示滞后。
    private func updateSeekTime() {
        let value = isExpanded ? Double(slider.value) * playbackDuration : playbackTime
        let hundredths = Int((max(0, value) * 100).rounded(.down))
        timeLabel.text = String(format: "%02d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
        let total = Int(max(0, playbackDuration))
        durationLabel.text = String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 准备目标形态及命中状态，外层在同一次动画中应用外观。
    func prepareExpansion(_ expanded: Bool) {
        isExpanded = expanded
        slider.isExpanded = expanded
        updateSeekTime()
        for button in [playButton, muteButton] {
            button.isUserInteractionEnabled = !expanded
            button.accessibilityElementsHidden = expanded
        }
        for label in [timeLabel, durationLabel] { label.accessibilityElementsHidden = !expanded }
        setNeedsLayout()
    }
    /// 与外层同步执行圆角、子控件显隐及轨道形变，支持动画打断。
    func applyExpansionAppearance() {
        cornerConfiguration = .uniformCorners(radius: .fixed(isExpanded ? 26 : 24))
        layoutIfNeeded()
        slider.layoutIfNeeded()
        playButton.alpha = isExpanded ? 0 : 1
        muteButton.alpha = isExpanded ? 0 : 1
        timeLabel.alpha = isExpanded ? 1 : 0
        durationLabel.alpha = isExpanded ? 1 : 0
    }
    /// 减少透明度时仍保持深色、高对比的媒体控件背景。
    func applyAccessibilitySettings() {
        effect = UIAccessibility.isReduceTransparencyEnabled ? nil : UIGlassEffect(style: .clear)
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled ? .secondarySystemBackground : .clear
    }
    /// 开始拖动的意图由外层统一处理，控件不自行播放或暂停。
    @objc private func seekBegan() { didBeginSeeking?() }
    /// 更新时间与目标，数值变化不额外改变展开状态。
    @objc private func seekChanged() {
        updateSeekTime()
        didChangeSeekPosition?(Double(slider.value), slider.isTracking)
    }
    /// 松手和取消共用结束回调，不等待播放器异步完成。
    @objc private func seekEnded() { didEndSeeking?(Double(slider.value)) }
}
