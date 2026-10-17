import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

final class ChatIncomingBannerView: QuickLayoutView {
    private let messageButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    var open: (() -> Void)?
    var close: (() -> Void)?
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor
        messageButton.contentHorizontalAlignment = .leading
        messageButton.titleLabel?.adjustsFontForContentSizeCategory = true
        messageButton.accessibilityIdentifier = "chat.banner.open"
        messageButton.addAction(UIAction { [weak self] _ in self?.open?() }, for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.accessibilityIdentifier = "chat.banner.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.close?() }, for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(alignment: .center, spacing: 4) {
            messageButton.resizable(axis: .horizontal).frame(minWidth: 160, minHeight: 64)
            closeButton.frame(width: 44, height: 44)
        }.padding(.all, 8)
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = UIColor.separator.cgColor
    }
    func configure(title: String, summary: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title; configuration.subtitle = summary
        configuration.titleAlignment = .leading
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = UIFont.preferredFont(forTextStyle: .headline); return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = UIFont.preferredFont(forTextStyle: .subheadline); return attributes
        }
        configuration.baseForegroundColor = .label
        messageButton.configuration = configuration
        messageButton.accessibilityLabel = title + ", " + summary
        closeButton.accessibilityLabel = Localization.text("chat.details.dismissBanner")
        semanticContentAttribute = Localization.currentUIKitDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        layer.borderColor = UIColor.separator.cgColor
        invalidateIntrinsicContentSize(); setNeedsQuickLayout()
    }
    func clearContent() {
        messageButton.configuration = nil
        messageButton.accessibilityLabel = nil
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("应用内消息") {
    let banner = ChatIncomingBannerView()
    banner.configure(title: "林沐", summary: "周末去海边走走吗？")
    return banner
}
#endif
