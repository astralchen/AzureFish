//
//  TypingBubbleView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 以三个圆点动画表示对方正在输入的气泡视图。
final class TypingBubbleView: QuickLayoutView {

    /// 按显示顺序排列的三个输入状态圆点。
    let dots: [UIView] = (0..<3).map { _ in UIView() }

    /// 定义 `TypingBubbleView` 的布局层级、间距和对齐方式。
    override var body: Layout {
        HStack(spacing: 4) {
            ForEach(dots) { dot in
                dot.frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    /// 使用指定初始边框创建 `TypingBubbleView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        for dot in dots {
            dot.backgroundColor = .secondaryLabel
            dot.layer.cornerRadius = 3.5
        }
        isAccessibilityElement = true
    }

    /// 不支持从归档创建 `TypingBubbleView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 进入窗口时按需启动圆点动画，离开窗口时移除动画。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            dots.forEach { $0.layer.removeAllAnimations() }
        } else {
            startAnimatingIfNeeded()
        }
    }

    /// 更新输入状态的辅助功能描述，并按需启动圆点动画。
    func configure(accessibilityLabel: String) {
        self.accessibilityLabel = accessibilityLabel
        startAnimatingIfNeeded()
    }

    /// 仅在视图可见且未启用减弱动态效果时启动错峰圆点动画。
    private func startAnimatingIfNeeded() {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            dots.forEach {
                $0.layer.removeAllAnimations()
                $0.alpha = 1
            }
            return
        }
        for (index, dot) in dots.enumerated() {
            guard dot.layer.animation(forKey: "imessage.typing") == nil else {
                continue
            }
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0.35, 1, 0.35]
            animation.keyTimes = [0, 0.5, 1]
            animation.duration = 0.9
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.15
            animation.repeatCount = .infinity
            dot.layer.add(animation, forKey: "imessage.typing")
        }
    }
}
