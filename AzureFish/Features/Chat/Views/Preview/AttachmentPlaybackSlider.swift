import UIKit

/// 基于 UISlider 保留辅助功能语义，自定义轨道几何及稳定的相对拖动坐标。
@available(iOS 26.0, *)
final class AttachmentPlaybackSlider: UISlider {
    /// 整条轨道统一裁剪外端圆角，填充分界保持竖直。
    private let trackView = UIView()
    /// 已播放部分不单独设置圆角，由外层轨道裁剪。
    private let fillView = UIView()
    /// 由宿主触摸形态控制厚度；异步播放回调只更新进度。
    var isExpanded = false { didSet { setNeedsLayout() } }
    /// 以手势起点的窗口坐标和轨道宽度计算位移，面板展开不能改变当前进度。
    private var dragOrigin: (x: CGFloat, value: Float, width: CGFloat)?

    /// 程序更新进度时同步可视填充，不发送用户操作事件。
    override var value: Float { didSet { updateFill() } }

    /// 隐藏系统轨道和滑块图像，保留 UISlider 的数值范围与 VoiceOver 行为。
    override init(frame: CGRect) {
        super.init(frame: frame)
        sliderStyle = .thumbless
        let empty = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        setMinimumTrackImage(empty, for: .normal)
        setMaximumTrackImage(empty, for: .normal)
        setThumbImage(empty, for: .normal)
        setThumbImage(empty, for: .highlighted)
        minimumTrackTintColor = .clear
        maximumTrackTintColor = .clear
        trackView.backgroundColor = UIColor.white.withAlphaComponent(0.24)
        trackView.clipsToBounds = true
        trackView.isUserInteractionEnabled = false
        fillView.backgroundColor = .white
        trackView.addSubview(fillView)
        addSubview(trackView)
        addTarget(self, action: #selector(progressChanged), for: .valueChanged)
    }

    /// 播放进度条仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 整条轨道都可起拖，按下不跳转；几何展开后仍使用按下时的逻辑坐标。
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        dragOrigin = (touch.location(in: window).x, value, max(1, bounds.width))
        isHighlighted = true
        return true
    }

    /// 按相对位移连续定位，反向拖动复用同一基准，不依赖变化中的可见宽度。
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let origin = dragOrigin else { return false }
        value = origin.value + Float((touch.location(in: window).x - origin.x) / origin.width) * (maximumValue - minimumValue)
        sendActions(for: .valueChanged)
        return true
    }

    /// 系统发送松手事件前释放本次逻辑坐标，宿主负责提交最终 seek。
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        dragOrigin = nil
        isHighlighted = false
        super.endTracking(touch, with: event)
    }

    /// 取消与松手共享清理边界，避免下一次拖动沿用旧的起点。
    override func cancelTracking(with event: UIEvent?) {
        dragOrigin = nil
        isHighlighted = false
        super.cancelTracking(with: event)
    }

    /// 常态 8 pt、拖动 15 pt，中心不随厚度改变；外层仍提供 44 pt 触摸高度。
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let height: CGFloat = isExpanded ? 15 : 8
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    /// 随宿主同一次动画更新宽度、厚度及外端圆角，避免切换图片造成跳变。
    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = trackRect(forBounds: bounds)
        trackView.layer.cornerRadius = trackView.bounds.height / 2
        bringSubviewToFront(trackView)
        updateFill()
    }

    /// 系统直接设置数值的路径也需更新自定义轨道。
    override func setValue(_ value: Float, animated: Bool) {
        super.setValue(value, animated: animated)
        updateFill()
    }

    /// 触摸及辅助功能产生值变化时更新填充，不额外发送重复进度事件。
    @objc private func progressChanged() { updateFill() }

    /// 用真实矩形宽度显示进度；零和满进度均由同一轨道裁剪处理。
    private func updateFill() {
        let range = maximumValue - minimumValue
        let fraction = range > 0 ? CGFloat((value - minimumValue) / range) : 0
        fillView.frame = CGRect(x: 0, y: 0, width: trackView.bounds.width * min(1, max(0, fraction)), height: trackView.bounds.height)
    }
}
