//
//  TimestampCell.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 在时间线中显示本地化时间分隔文本的单元格。
final class TimestampCell: QuickLayoutCollectionViewCell {

    /// 显示消息组时间的居中标签。
    let timestampLabel = UILabel()

    /// 定义 `TimestampCell` 的布局层级、间距和对齐方式。
    override var body: Layout {
        timestampLabel
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// 使用指定初始边框创建 `TimestampCell`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        quickLayoutHorizontalFlexibility = .fixedSize
        quickLayoutVerticalFlexibility = .fullyFlexible
        timestampLabel.font = .preferredFont(forTextStyle: .caption1)
        timestampLabel.adjustsFontForContentSizeCategory = true
        timestampLabel.textColor = .secondaryLabel
        timestampLabel.textAlignment = .center
        timestampLabel.numberOfLines = 0
        timestampLabel.isAccessibilityElement = true
    }

    /// 不支持从归档创建 `TimestampCell`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 应用时间分隔文本，并同步可访问标签与布局。
    func configure(_ timestamp: TimestampPresentation) {
        timestampLabel.text = timestamp.text
        timestampLabel.accessibilityLabel = timestamp.text
        setNeedsQuickLayout()
    }

    /// 为复用清理 `TimestampCell` 的内容与临时状态。
    override func prepareForReuse() {
        super.prepareForReuse()
        timestampLabel.text = nil
        timestampLabel.accessibilityLabel = nil
    }
}
