//
//  TextBubbleView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 根据消息方向显示文本与圆角气泡轮廓的视图。
final class TextBubbleView: QuickLayoutView {

    /// 显示消息正文，由系统识别联系方式、日期、航班、快递、金额和单位。
    let messageTextView = MessageBodyTextView()
    /// 按消息方向裁剪气泡圆角的形状遮罩。
    private let bubbleMask = QuickLayoutShapeView(frame: .zero)
    /// 当前消息的接收或发出方向，用于确定气泡外观与语义对齐。
    private var direction: MessageDirection = .incoming
    private var formattedText: MessageText?

    /// 定义 `TextBubbleView` 的布局层级、间距和对齐方式。
    override var body: Layout {
        messageTextView
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    /// 使用指定初始边框创建 `TextBubbleView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        messageTextView.font = .preferredFont(forTextStyle: .body)
        messageTextView.adjustsFontForContentSizeCategory = true
        messageTextView.textAlignment = .natural
        bubbleMask.fillColor = .black
        mask = bubbleMask
        isAccessibilityElement = false
    }

    /// 不支持从归档创建 `TextBubbleView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var menuPreviewPath: UIBezierPath {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left = direction == .incoming ? !rtl : rtl
        return UIBezierPath(cgPath: Self.roundedPath(in: bounds, topLeft: 18, topRight: 18,
                                                    bottomLeft: left ? 5 : 18, bottomRight: left ? 18 : 5))
    }

    /// 根据当前边界更新 `TextBubbleView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        // 插入消息与输入栏收起会在 UIView 动画事务中布局。正文已按最终宽度换行，
        // 若文本视图及 TextKit 子视图仍从旧尺寸展开，长文本会暂时被裁剪。
        // 内部几何同步到最终尺寸，位置过渡继续交给外层气泡和 Cell。
        UIView.performWithoutAnimation {
            super.layoutSubviews()
            messageTextView.layoutIfNeeded()
            updateBubbleMask()
        }
    }

    /// 应用消息文本、收发方向和辅助功能信息，并请求重新布局。
    func configure(_ message: MessagePresentation) {
        direction = message.direction
        if case .richText(let text) = message.content { formattedText = text } else { formattedText = nil }
        messageTextView.attributedText = nil
        messageTextView.font = .preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        messageTextView.text = message.text
        switch message.direction {
        case .incoming:
            backgroundColor = .secondarySystemFill
            messageTextView.textColor = .label
        case .outgoing:
            backgroundColor = .systemBlue
            messageTextView.textColor = .white
        }
        messageTextView.linkTextAttributes = [
            .foregroundColor: message.direction == .outgoing ? UIColor.white : UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        renderFormattedText()
        messageTextView.accessibilityLabel = message.text
        accessibilityLabel = message.text
        setNeedsQuickLayout()
        setNeedsLayout()
    }

    /// 清空文本与辅助功能信息，恢复未配置的气泡状态。
    func reset() {
        messageTextView.endMessageSelection()
        messageTextView.usesMessageMenu = false
        direction = .incoming
        formattedText = nil
        messageTextView.attributedText = nil
        messageTextView.text = nil
        messageTextView.accessibilityLabel = nil
        accessibilityLabel = nil
        backgroundColor = .clear
        bubbleMask.shape = nil
        bubbleMask.layoutIfNeeded()
        setNeedsQuickLayout()
    }

    private func renderFormattedText() {
        guard let formattedText else { return }
        messageTextView.attributedText = formattedText.attributedString(
            font: .preferredFont(forTextStyle: .body, compatibleWith: traitCollection),
            color: direction == .outgoing ? .white : .label
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            renderFormattedText()
            setNeedsQuickLayout()
        }
    }

    /// 根据当前边界和收发方向更新气泡遮罩路径。
    private func updateBubbleMask() {
        guard bounds.width > 0, bounds.height > 0 else {
            bubbleMask.shape = nil
            bubbleMask.layoutIfNeeded()
            return
        }
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let compactBottomLeft = direction == .incoming ? !isRTL : isRTL
        let compactBottomRight = !compactBottomLeft
        bubbleMask.frame = bounds
        bubbleMask.shape = QuickLayoutAnyShape { rect in
            Self.roundedPath(
                in: rect,
                topLeft: 18,
                topRight: 18,
                bottomLeft: compactBottomLeft ? 5 : 18,
                bottomRight: compactBottomRight ? 5 : 18
            )
        }
        bubbleMask.layoutIfNeeded()
    }

    /// 返回分别指定四个圆角半径的闭合矩形路径。
    ///
    /// - Parameters:
    ///   - rect: 需要绘制的矩形区域。
    ///   - topLeft: 左上角半径，单位为点。
    ///   - topRight: 右上角半径，单位为点。
    ///   - bottomLeft: 左下角半径，单位为点。
    ///   - bottomRight: 右下角半径，单位为点。
    /// - Returns: 用于气泡遮罩的闭合路径。
    nonisolated private static func roundedPath(
        in rect: CGRect,
        topLeft: CGFloat,
        topRight: CGFloat,
        bottomLeft: CGFloat,
        bottomRight: CGFloat
    ) -> CGPath {
        let maximumRadius = min(rect.width, rect.height) / 2
        let tl = min(topLeft, maximumRadius)
        let tr = min(topRight, maximumRadius)
        let bl = min(bottomLeft, maximumRadius)
        let br = min(bottomRight, maximumRadius)
        let path = UIBezierPath()

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
            radius: tr,
            startAngle: -.pi / 2,
            endAngle: 0,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
            radius: br,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
            radius: bl,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
            radius: tl,
            startAngle: .pi,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        path.close()
        return path.cgPath
    }
}

#if DEBUG
/// 创建承载指定消息文本气泡的独立预览控制器。
@available(iOS 16.0, *)
@MainActor
private func makeTextBubbleViewPreview(
    _ message: MessagePresentation
) -> UIViewController {
    let backgroundView = UIView()
    backgroundView.backgroundColor = .systemBackground
    let bubbleView = TextBubbleView(frame: .zero)
    bubbleView.configure(message)
    return QuickLayoutHostingController {
        ZStack {
            backgroundView.resizable()
            bubbleView
        }
        .frame(width: 330, height: 110)
    }
}

/// 创建承载指定文本消息单元格的独立预览控制器。
@available(iOS 16.0, *)
@MainActor
private func makeTextBubbleCellPreview(
    _ message: MessagePresentation
) -> UIViewController {
    let backgroundView = UIView()
    backgroundView.backgroundColor = .systemBackground
    let cell = TextBubbleCell(frame: .zero)
    cell.configure(message)
    return QuickLayoutHostingController {
        ZStack {
            backgroundView.resizable()
            cell.resizable().frame(width: 390, height: 86)
        }
    }
}

/// 创建使用固定示例时间的时间分隔单元格预览。
@available(iOS 16.0, *)
@MainActor
private func makeTimestampCellPreview() -> UIViewController {
    let cell = TimestampCell(frame: .zero)
    cell.configure(ConversationPreviewData.timestamp)
    return QuickLayoutHostingController {
        cell.resizable().frame(width: 390, height: 52)
    }
}

/// 创建用于检查输入圆点动画及外观的气泡视图预览。
@available(iOS 16.0, *)
@MainActor
private func makeTypingBubbleViewPreview() -> UIViewController {
    let backgroundView = UIView()
    backgroundView.backgroundColor = .systemBackground
    let typingView = TypingBubbleView(frame: .zero)
    typingView.configure(
        accessibilityLabel: ConversationPreviewData
            .typingAccessibilityLabel
    )
    return QuickLayoutHostingController {
        ZStack {
            backgroundView.resizable()
            typingView
        }
        .frame(width: 160, height: 90)
    }
}

/// 创建用于检查时间线输入状态布局的单元格预览。
@available(iOS 16.0, *)
@MainActor
private func makeTypingCellPreview() -> UIViewController {
    let cell = TypingCell(frame: .zero)
    cell.configure(
        accessibilityLabel: ConversationPreviewData
            .typingAccessibilityLabel
    )
    return QuickLayoutHostingController {
        cell.resizable().frame(width: 390, height: 62)
    }
}

@available(iOS 17.0, *)
#Preview("文本气泡 View · 收到") {
    makeTextBubbleViewPreview(ConversationPreviewData.incomingMessage)
}

@available(iOS 17.0, *)
#Preview("文本气泡 View · 发出") {
    makeTextBubbleViewPreview(ConversationPreviewData.outgoingMessage)
}

@available(iOS 17.0, *)
#Preview("文本气泡 Cell · 收到") {
    makeTextBubbleCellPreview(ConversationPreviewData.incomingMessage)
}

@available(iOS 17.0, *)
#Preview("文本气泡 Cell · 发出") {
    makeTextBubbleCellPreview(ConversationPreviewData.outgoingMessage)
}

@available(iOS 17.0, *)
#Preview("消息时间 Cell") {
    makeTimestampCellPreview()
}

@available(iOS 17.0, *)
#Preview("输入中气泡 View") {
    makeTypingBubbleViewPreview()
}

@available(iOS 17.0, *)
#Preview("输入中 Cell") {
    makeTypingCellPreview()
}
#endif
