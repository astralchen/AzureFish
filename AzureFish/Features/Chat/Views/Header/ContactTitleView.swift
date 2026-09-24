//
//  ContactTitleView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit

/// 在导航栏中呈现联系人头像、名称与副标题的自适应视图。
final class ContactTitleView: QuickLayoutView {

    /// 导航标题允许占用的最大宽度，单位为点。
    private static let maximumTitleWidth: CGFloat = 220
    /// 用于约束联系人标题的标准导航栏内容高度，单位为点。
    private static let navigationBarHeight: CGFloat = 44

    /// 显示联系人头像的图像视图。
    let avatarView = UIImageView()
    /// 显示联系人名称的标签。
    let nameLabel = UILabel()
    /// 显示会话渠道或当前状态的副标题标签。
    let subtitleLabel = UILabel()

    /// 定义 `ContactTitleView` 的布局层级、间距和对齐方式。
    override var body: Layout {
        HStack(spacing: 7) {
            avatarView.resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                nameLabel
                subtitleLabel
            }
        }
    }

    /// 使用指定初始边框创建 `ContactTitleView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        avatarView.image = UIImage(systemName: "person.crop.circle.fill")
        avatarView.tintColor = .systemGray
        avatarView.contentMode = .scaleAspectFit

        nameLabel.text = "Alex"
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textAlignment = .natural
        nameLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = .preferredFont(forTextStyle: .caption2)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .natural
        subtitleLabel.lineBreakMode = .byTruncatingTail
        isAccessibilityElement = true
    }

    /// `ContactTitleView` 在当前内容与布局约束下的固有尺寸。
    override var intrinsicContentSize: CGSize {
        fittingTitleSize(
            in: CGSize(
                width: Self.maximumTitleWidth,
                height: Self.navigationBarHeight
            )
        )
    }

    /// 导航栏可能在标题仍为零尺寸时先询问 fitting size；此时使用受控上限向
    /// QuickLayout 提案，避免首次测量只得到头像或空内容宽度。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        fittingTitleSize(
            in: CGSize(
                width: size.width > 0
                    ? min(size.width, Self.maximumTitleWidth)
                    : Self.maximumTitleWidth,
                height: size.height > 0
                    ? min(size.height, Self.navigationBarHeight)
                    : Self.navigationBarHeight
            )
        )
    }

    /// 不支持从归档创建 `ContactTitleView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新联系人副标题、辅助功能描述及标题尺寸。
    func configure(subtitle: String) {
        subtitleLabel.text = subtitle
        accessibilityLabel = "Alex, \(subtitle)"
        invalidateIntrinsicContentSize()
        setNeedsQuickLayout()
        superview?.setNeedsLayout()
    }

    /// 在导航栏宽高约束内测量联系人标题所需尺寸。
    private func fittingTitleSize(in proposal: CGSize) -> CGSize {
        let measuredSize = super.sizeThatFits(proposal)
        return CGSize(
            width: min(Self.maximumTitleWidth, ceil(measuredSize.width)),
            height: min(
                Self.navigationBarHeight,
                max(30, ceil(measuredSize.height))
            )
        )
    }
}

#if DEBUG
/// 创建指定布局方向的联系人导航标题预览。
@available(iOS 16.0, *)
@MainActor
private func makeContactTitlePreview(
    direction: UIUserInterfaceLayoutDirection
) -> UIViewController {
    let backgroundView = UIView()
    backgroundView.backgroundColor = .systemBackground
    let titleView = ContactTitleView(frame: .zero)
    titleView.semanticContentAttribute = direction == .rightToLeft
        ? .forceRightToLeft
        : .forceLeftToRight
    titleView.configure(subtitle: ConversationPreviewData.contactSubtitle)
    titleView.sizeToFit()
    return QuickLayoutHostingController {
        ZStack {
            backgroundView.resizable()
            titleView.frame(width: 220, height: 44)
        }
        .frame(width: 280, height: 88)
    }
}

@available(iOS 17.0, *)
#Preview("联系人导航标题") {
    makeContactTitlePreview(direction: .leftToRight)
}

@available(iOS 17.0, *)
#Preview("联系人导航标题 · RTL") {
    makeContactTitlePreview(direction: .rightToLeft)
}
#endif
