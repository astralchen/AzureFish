//
//  TypingCell.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 在时间线语义起始侧显示输入状态气泡的单元格。
final class TypingCell: QuickLayoutCollectionViewCell {

    /// 显示三个圆点及辅助功能输入状态的气泡视图。
    let typingView = TypingBubbleView(frame: .zero)

    /// 需要随单元格同步更新布局方向的内容视图。
    override var quickLayoutDirectionViews: [UIView] {
        super.quickLayoutDirectionViews + [typingView]
    }

    /// 定义 `TypingCell` 的布局层级、间距和对齐方式。
    override var body: Layout {
        HStack(spacing: 0) {
            typingView
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    /// 使用指定初始边框创建 `TypingCell`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
    }

    /// 不支持从归档创建 `TypingCell`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新输入状态气泡的辅助功能描述，并使布局失效。
    func configure(accessibilityLabel: String) {
        typingView.configure(accessibilityLabel: accessibilityLabel)
        setNeedsQuickLayout()
    }
}
