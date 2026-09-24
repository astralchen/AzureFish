import PhotosUI
import UIKit

/// 胶囊保持紧凑外观，独立扩大命中区域，不改变照片几何。
@available(iOS 26.0, *)
final class LivePhotoBadgeButton: UIButton {
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
    private var arrowSide: CGFloat = 10
    override init(frame: CGRect) {
        super.init(frame: frame)
        showsMenuAsPrimaryAction = true
        accessibilityIdentifier = "imessage.preview.live"
        tintColor = .secondaryLabel
        chevron.tintColor = .secondaryLabel
        chevron.isUserInteractionEnabled = false
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mode: LivePhotoPlaybackMode, didSelect: @escaping (LivePhotoPlaybackMode) -> Void) {
        let title = Localization.text(mode == .off ? "imessage.preview.live.offState" : mode.titleKey)
        let font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.indicator = .none
        config.baseForegroundColor = .secondaryLabel
        config.image = mode.isContinuous ? UIImage(systemName: mode.symbol) : PHLivePhotoView.livePhotoBadgeImage(options: mode == .off ? .liveOff : [])
        config.preferredSymbolConfigurationForImage = .init(pointSize: font.pointSize)
        // 系统实况标志是位图，按文字高度缩放，避免使用其原始资源尺寸撑高胶囊。
        if let image = config.image {
            let side = font.lineHeight
            config.image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }.withRenderingMode(.alwaysTemplate)
        }
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: font]))
        config.imagePadding = 4
        arrowSide = max(10, font.pointSize * 0.8)
        chevron.preferredSymbolConfiguration = .init(pointSize: arrowSide, weight: .medium)
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 5, bottom: 2, trailing: arrowSide + 10)
        configuration = config
        accessibilityLabel = Localization.text("imessage.preview.live.on")
        accessibilityValue = title
        menu = UIMenu(children: LivePhotoPlaybackMode.allCases.map { option in
            UIAction(title: Localization.text(option.titleKey), image: UIImage(systemName: option.symbol),
                     state: mode == option ? .on : .off) { _ in didSelect(option) }
        })
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        chevron.frame = CGRect(x: rtl ? 5 : bounds.width - arrowSide - 5,
            y: (bounds.height - arrowSide) / 2, width: arrowSide, height: arrowSide)
        bringSubviewToFront(chevron)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2),
                       dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }
}
