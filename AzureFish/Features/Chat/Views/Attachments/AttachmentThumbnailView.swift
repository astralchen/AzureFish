//
//  AttachmentThumbnailView.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 内层沿实际图片边缘裁剪并描边，外层绘制阴影，避免圆角裁掉阴影。
@available(iOS 17.0, *)
final class AttachmentThumbnailView: UIView {
    /// 显示当前媒体图像的图像视图。
    private let imageView = MediaImageView()

    /// 缩略图视图显示的图像；设置后同步到内层图像视图。
    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue; setNeedsLayout() }
    }

    /// 设置媒体缩略图 URL，实际显示像素由布局阶段决定。
    func setThumbnail(_ url: URL?, placeholder: UIImage? = nil) { imageView.setThumbnail(url, placeholder: placeholder) }

    /// 缩略图的内容缩放模式；变化时同步到内层图像视图。
    override var contentMode: UIView.ContentMode {
        didSet { setNeedsLayout() }
    }

    /// 使用指定初始边框创建 `AttachmentThumbnailView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = AttachmentCardStyle.thumbnailCornerRadius
        imageView.layer.borderWidth = 0.5
        addSubview(imageView)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 2)
        updateBorderColor()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: AttachmentThumbnailView, _: UITraitCollection) in
            view.updateBorderColor()
        }
    }

    /// 不支持从归档创建 `AttachmentThumbnailView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 根据当前外观解析动态描边颜色并更新缩略图边框。
    private func updateBorderColor() {
        imageView.layer.borderColor = UIColor.label.withAlphaComponent(0.24)
            .resolvedColor(with: traitCollection).cgColor
    }

    /// 根据当前边界更新 `AttachmentThumbnailView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        super.layoutSubviews()
        var imageRect = bounds
        if contentMode == .scaleAspectFit, let image, !image.isSymbolImage,
           image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageRect = CGRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = imageRect
        imageView.contentMode = image?.isSymbolImage == true ? .center : contentMode
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .regular)
        imageView.backgroundColor = image?.isSymbolImage == true ? .secondarySystemGroupedBackground : .clear
        imageView.isHidden = false
        layer.shadowPath = image == nil ? nil
            : UIBezierPath(roundedRect: imageRect,
                           cornerRadius: AttachmentCardStyle.thumbnailCornerRadius).cgPath
        CATransaction.commit()
    }
}
