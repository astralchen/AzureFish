//
//  WaveformView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 用紧凑柱形区分已播放和未播放采样的波形视图。
///
/// 此视图仅用于装饰。所属的播放控件为对应音频附件提供 VoiceOver 标签和值。
final class WaveformView: UIView {

    /// 波形柱的首选宽度。
    ///
    /// 当所有柱形无法在当前边界内完整显示时，视图会等比收窄柱形；当采样数量
    /// 较少时不会横向拉伸柱形，而是将完整波形居中显示。
    var barWidth: CGFloat = 2 {
        didSet { setNeedsDisplay() }
    }

    /// 相邻波形柱之间的首选间距。
    ///
    /// 当当前边界不足时，视图会先收窄间距，再收窄柱形。
    var barSpacing: CGFloat = 2 {
        didSet { setNeedsDisplay() }
    }

    /// 消息波形使用完整可用宽度；录音面板保留原来的固定柱间距。
    var fillsAvailableWidth = false {
        didSet { setNeedsDisplay() }
    }

    /// 位于语义起始侧、使用未播放颜色绘制的波形比例。
    ///
    /// 值会被限制在 `0...1`。录音面板使用此属性表达设计图中的旧采样渐隐区；
    /// 播放波形应保留默认值 `0`，继续仅由 ``progress`` 区分播放进度。
    var fadedLeadingFraction: CGFloat = 0 {
        didSet { setNeedsDisplay() }
    }

    /// 波形柱允许显示的最小高度。
    ///
    /// 默认值适用于消息气泡；Composer 可以使用更紧凑的设计尺寸。
    var minimumBarHeight: CGFloat = 3 {
        didSet { setNeedsDisplay() }
    }

    /// 波形柱允许显示的最大高度。
    ///
    /// 值为 `nil` 时使用视图的完整高度。设置该值只约束柱形绘制，
    /// 不改变视图参与布局和垂直居中的边界。
    var maximumBarHeight: CGFloat? {
        didSet { setNeedsDisplay() }
    }

    /// 位于 `0...1` 范围内的归一化波形采样。
    var samples: [Float] = [] {
        didSet { setNeedsDisplay() }
    }

    /// 位于 `0...1` 范围内的归一化播放位置。
    var progress: Double = 0 {
        didSet { setNeedsDisplay() }
    }

    /// 播放位置之后的波形采样所使用的颜色。
    var unplayedColor: UIColor = .secondaryLabel {
        didSet { setNeedsDisplay() }
    }

    /// 播放位置之前的波形采样所使用的颜色。
    var playedColor: UIColor = .label {
        didSet { setNeedsDisplay() }
    }

    /// 使用指定初始边框创建 `WaveformView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    /// 不支持从归档创建 `WaveformView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 按采样振幅绘制波形，并根据布局方向与播放进度区分已播放区域。
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !samples.isEmpty else {
            return
        }
        let count = samples.count
        let preferredBarWidth = max(0.5, barWidth)
        let preferredSpacing = max(0, barSpacing)
        let resolvedSpacing: CGFloat
        if count > 1 {
            let fittingSpacing = max(0, (rect.width - preferredBarWidth * CGFloat(count)) / CGFloat(count - 1))
            resolvedSpacing = fillsAvailableWidth ? fittingSpacing : min(preferredSpacing, fittingSpacing)
        } else {
            resolvedSpacing = 0
        }
        let availableWidth = max(
            0.5,
            rect.width - resolvedSpacing * CGFloat(count - 1)
        )
        let resolvedBarWidth = min(
            preferredBarWidth,
            availableWidth / CGFloat(count)
        )
        let contentWidth = resolvedBarWidth * CGFloat(count)
            + resolvedSpacing * CGFloat(count - 1)
        let leadingX = rect.midX - contentWidth / 2
        let isRightToLeft = effectiveUserInterfaceLayoutDirection
            == .rightToLeft
        let resolvedProgress = min(1, max(0, progress))
        let resolvedFadedFraction = min(1, max(0, fadedLeadingFraction))

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(resolvedBarWidth)
        for (index, sample) in samples.enumerated() {
            let displayIndex = isRightToLeft ? count - index - 1 : index
            let x = leadingX + resolvedBarWidth / 2
                + CGFloat(displayIndex)
                    * (resolvedBarWidth + resolvedSpacing)
            let maximumHeight = min(
                rect.height,
                max(0, maximumBarHeight ?? rect.height)
            )
            let minimumHeight = min(
                maximumHeight,
                max(0, minimumBarHeight)
            )
            let height = max(
                minimumHeight,
                maximumHeight * CGFloat(min(1, max(0.08, sample)))
            )
            let normalizedIndex = count == 1
                ? 0
                : Double(index) / Double(count - 1)
            let usesFadedLeadingColor = CGFloat(normalizedIndex)
                < resolvedFadedFraction
            let color: UIColor
            if usesFadedLeadingColor {
                color = unplayedColor
            } else {
                color = Self.isSamplePlayed(
                    at: index,
                    count: count,
                    progress: resolvedProgress
                )
                    ? playedColor
                    : unplayedColor
            }
            context.setStrokeColor(color.cgColor)
            context.move(to: CGPoint(x: x, y: rect.midY - height / 2))
            context.addLine(to: CGPoint(x: x, y: rect.midY + height / 2))
            context.strokePath()
        }
        context.restoreGState()
    }

    /// 返回指定波形柱在当前进度下是否已经播放。
    ///
    /// 使用柱形中心点判断播放进度，确保零进度不会提前高亮第一根柱形，
    /// 完整进度仍会覆盖全部柱形。
    ///
    /// - Parameters:
    ///   - index: 波形柱在采样数组中的索引。
    ///   - count: 波形柱总数。
    ///   - progress: 位于 `0...1` 范围内的播放位置。
    /// - Returns: 当前波形柱已经越过播放位置时返回 `true`。
    static func isSamplePlayed(
        at index: Int,
        count: Int,
        progress: Double
    ) -> Bool {
        guard count > 0, index >= 0, index < count else {
            return false
        }
        let resolvedProgress = min(1, max(0, progress))
        guard resolvedProgress > 0 else {
            return false
        }
        guard resolvedProgress < 1 else {
            return true
        }
        let sampleCenter = (Double(index) + 0.5) / Double(count)
        return sampleCenter <= resolvedProgress
    }
}
