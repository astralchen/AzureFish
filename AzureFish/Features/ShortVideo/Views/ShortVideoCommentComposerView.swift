import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 可增长的评论输入区；输入控件保持同一实例，尺寸或语言切换不丢失正文与焦点。
final class ShortVideoCommentComposerView: QuickLayoutView, UITextViewDelegate {
    let input = UITextView()
    let send = UIButton(type: .system)
    private let placeholder = UILabel()
    private var busy = false
    private lazy var inputBinding = Localization.inputContext(for: self).makeTextInputBinding(to: input)
    var textChanged: ((String) -> Void)?
    var heightDidChange: (() -> Void)?
    private var inputHeight: CGFloat = 44
    private var measuredWidth: CGFloat = 0
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        placeholder.textColor = .placeholderText; placeholder.numberOfLines = 1
        placeholder.font = .preferredFont(forTextStyle: .body); placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false; placeholder.isAccessibilityElement = false
        input.delegate = self; input.backgroundColor = .secondarySystemBackground
        input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
        input.layer.cornerRadius = 22; input.textContainerInset = .init(top: 10, left: 8, bottom: 10, right: 8)
        input.accessibilityIdentifier = "shortVideo.comment.input"
        send.accessibilityIdentifier = "shortVideo.comment.send"
        if #available(iOS 26.0, *) { send.configuration = .prominentGlass() }
        else { send.configuration = .borderedProminent() }
        send.configuration?.image = UIImage(systemName: "arrow.up")
        send.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 17, weight: .semibold)
        send.configuration?.cornerStyle = .capsule
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .leading) {
                input.resizable(axis: .horizontal).frame(height: inputHeight)
                if input.text.isEmpty {
                    placeholder.resizable(axis: .horizontal).padding(.horizontal, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { [weak self] width in
                    self?.updateHeight(width: width)
                })
            send.resizable().frame(width: 44, height: 44)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }
    func textViewDidChange(_ textView: UITextView) {
        textChanged?(textView.text ?? "")
        updateSendState(); setNeedsQuickLayout(); updateHeight(width: measuredWidth)
    }
    func applyLayoutDirection(_ direction: UIUserInterfaceLayoutDirection) {
        let attribute = direction.appLayoutDirection.semanticContentAttribute
        semanticContentAttribute = attribute; input.semanticContentAttribute = attribute
        inputBinding.refresh(); setNeedsQuickLayout()
    }
    func apply(draft: String, busy: Bool) {
        self.busy = busy
        if input.text != draft { input.text = draft }
        inputBinding.refresh()
        input.isEditable = !busy
        placeholder.text = Localization.text("shortVideo.commentPlaceholder")
        updateSendState(); setNeedsQuickLayout()
        input.accessibilityLabel = Localization.text("shortVideo.commentInput")
        send.accessibilityLabel = Localization.text("shortVideo.send")
        updateHeight(width: measuredWidth)
    }
    private func updateSendState() {
        send.isEnabled = !busy && !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.configuration?.baseBackgroundColor = .systemPink
        send.configuration?.showsActivityIndicator = busy
    }
    private func updateHeight(width: CGFloat) {
        guard width > 0 else { return }; measuredWidth = width
        let line = (input.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let minimum = max(44, line + 20), maximum = max(minimum, line * 4 + 20)
        let measured = input.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(maximum, max(minimum, ceil(measured)))
        input.isScrollEnabled = measured > maximum
        guard abs(inputHeight - height) > 0.5 else { return }
        inputHeight = height; setNeedsQuickLayout(); heightDidChange?()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateHeight(width: measuredWidth)
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("评论输入区长文本") {
    let view = ShortVideoCommentComposerView()
    view.apply(draft: "保留草稿并根据输入内容调整高度。\nA comment draft stays editable when the window changes.", busy: false)
    return view
}
#endif
