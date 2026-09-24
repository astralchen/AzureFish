//
//  LinkPreviewView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 使用已经缓存的元数据渲染链接，测量与绘制共用同一份内容和字体。
final class LinkPreviewView: UIView {
    /// 初始化时绑定的链接元数据；为 `nil` 时显示空预览。
    let link: LinkAttachment?
    /// 显示网页封面的图像视图。
    private let coverView = UIImageView()
    /// 显示网站图标的图像视图，与大尺寸封面分开布局。
    private let siteIconView = UIImageView()
    /// 显示网页标题的多行标签。
    private let titleLabel = UILabel()
    /// 显示网页主机名的标签。
    private let domainLabel = UILabel()
    /// 指示紧凑链接布局是否应为删除按钮保留文字空间的布尔值。
    var showsRemoveButton = false { didSet { setNeedsLayout() } }
    /// 指示当前预览是否具有可显示封面的布尔值。
    var hasCover: Bool { coverView.image != nil }
    /// 指示当前预览是否具有可显示站点图标的布尔值。
    var hasSiteIcon: Bool { siteIconView.image != nil }

    /// 创建使用指定缓存链接元数据的预览视图，不启动网络请求。
    init(link: LinkAttachment? = nil) {
        self.link = link
        super.init(frame: .zero)
        coverView.image = link?.imageURL.flatMap { UIImage(contentsOfFile: $0.path) }
        siteIconView.image = link?.iconURL.flatMap { UIImage(contentsOfFile: $0.path) }
        coverView.contentMode = .scaleAspectFit
        coverView.backgroundColor = .systemGray6
        siteIconView.contentMode = .scaleAspectFit
        siteIconView.layer.cornerRadius = 4
        siteIconView.clipsToBounds = true
        titleLabel.text = link?.title ?? link?.url.host ?? link?.url.absoluteString
        domainLabel.text = link?.url.host ?? link?.url.absoluteString
        titleLabel.numberOfLines = hasCover ? 2 : 1
        titleLabel.lineBreakMode = .byTruncatingTail
        domainLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .label
        domainLabel.textColor = .secondaryLabel
        backgroundColor = .systemGray5
        [coverView, siteIconView, titleLabel, domainLabel].forEach(addSubview)
        coverView.isHidden = !hasCover
        siteIconView.isHidden = hasCover || !hasSiteIcon
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    /// 不支持从归档创建 `LinkPreviewView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 根据当前内容大小类别更新动态字体。
    private func updateFonts() {
        titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 16, weight: .semibold), compatibleWith: traitCollection)
        domainLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
    }
    /// 根据卡片宽度计算受限的封面高度，单位为点。
    private func coverHeight(width: CGFloat) -> CGFloat {
        guard let image = coverView.image, image.size.width > 0 else { return 0 }
        return ceil(width * min(0.75, max(0.45, image.size.height / image.size.width)))
    }
    /// 返回 `LinkPreviewView` 在指定建议尺寸下所需的大小。
    ///
    /// - Parameter size: 父视图提供的建议尺寸。
    /// - Returns: 当前内容对应的适配尺寸。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        updateFonts()
        let maximumWidth = max(1, size.width)
        let iconSpace: CGFloat = hasSiteIcon && !hasCover ? 44 : 0
        let removeSpace: CGFloat = showsRemoveButton && !hasCover ? 36 : 0
        let naturalWidth = max(titleLabel.intrinsicContentSize.width, domainLabel.intrinsicContentSize.width)
            + 24 + iconSpace + removeSpace
        let width = hasCover ? maximumWidth : min(maximumWidth, max(110, ceil(naturalWidth)))
        let textWidth = max(1, width - 24 - iconSpace - removeSpace)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)).height)
        let textHeight = titleHeight + 2 + ceil(domainLabel.font.lineHeight)
        return CGSize(width: width, height: hasCover
            ? coverHeight(width: width) + textHeight + 16
            : max(54, textHeight + 16))
    }
    /// 根据当前边界更新 `LinkPreviewView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        super.layoutSubviews()
        updateFonts()
        let headerHeight = hasCover ? coverHeight(width: bounds.width) : 0
        coverView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        var content = CGRect(x: 12, y: headerHeight + 8, width: max(1, bounds.width - 24),
                             height: max(1, bounds.height - headerHeight - 16))
        if showsRemoveButton && !hasCover { content.size.width = max(1, content.width - 36) }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if hasSiteIcon && !hasCover {
            siteIconView.frame = CGRect(x: rtl ? content.minX : content.maxX - 34,
                y: content.midY - 17, width: 34, height: 34)
            if rtl { content.origin.x += 44 }
            content.size.width = max(1, content.width - 44)
        }
        let titleHeight = min(ceil(titleLabel.sizeThatFits(CGSize(width: content.width,
            height: CGFloat.greatestFiniteMagnitude)).height), content.height)
        titleLabel.textAlignment = rtl ? .right : .left
        domainLabel.textAlignment = titleLabel.textAlignment
        titleLabel.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: titleHeight)
        domainLabel.frame = CGRect(x: content.minX, y: titleLabel.frame.maxY + 2, width: content.width,
                                  height: ceil(domainLabel.font.lineHeight))
    }
}
