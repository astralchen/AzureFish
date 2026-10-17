import UIKit
import QuickLayout
import QuickLayoutKit

/// 原生输入控件与 QuickLayout 标签组合，输入在本地化刷新时保持原对象和选区。
final class AccountField: QuickLayoutView {
    let input = UITextField()
    private let label = UILabel()
    private let fill = UIView()
    private let reveal = UIButton(type: .system)
    private let key: String
    private let secure: Bool
    init(key: String, secure: Bool = false, identifier: String) {
        self.key = key; self.secure = secure
        super.init(frame: .zero)
        input.font = .preferredFont(forTextStyle: .body); input.adjustsFontForContentSizeCategory = true
        input.isSecureTextEntry = secure; input.autocorrectionType = .no; input.spellCheckingType = .no
        input.accessibilityIdentifier = identifier
        if secure { input.textContentType = .password; input.semanticContentAttribute = .forceLeftToRight; input.autocapitalizationType = .none; input.keyboardType = .asciiCapable }
        label.font = .preferredFont(forTextStyle: .footnote); label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel; label.numberOfLines = 0; label.textAlignment = .natural
        reveal.setImage(UIImage(systemName: "eye"), for: .normal)
        reveal.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let text = self.input.text
            let selection = self.input.selectedTextRange.map {
                (self.input.offset(from: self.input.beginningOfDocument, to: $0.start),
                 self.input.offset(from: self.input.beginningOfDocument, to: $0.end))
            }
            self.input.isSecureTextEntry.toggle()
            self.input.text = text
            if let selection,
               let start = self.input.position(from: self.input.beginningOfDocument, offset: selection.0),
               let end = self.input.position(from: self.input.beginningOfDocument, offset: selection.1) {
                self.input.selectedTextRange = self.input.textRange(from: start, to: end)
            }
            self.reloadText()
        }, for: .touchUpInside)
        fill.backgroundColor = .secondarySystemBackground; fill.layer.cornerRadius = 14
        reloadText()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func reloadText() {
        label.text = Localization.text(key); input.accessibilityLabel = label.text
        label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        input.placeholder = label.text
        reveal.accessibilityLabel = Localization.text("account.design.\(input.isSecureTextEntry ? "showPassword" : "hidePassword")")
        reveal.setImage(UIImage(systemName: input.isSecureTextEntry ? "eye" : "eye.slash"), for: .normal)
        setNeedsQuickLayout()
    }
    override var body: Layout {
        VStack(alignment: .leading, spacing: 8) {
            label
            ZStack {
                fill.resizable()
                HStack(spacing: 4) {
                    input.resizable().frame(minHeight: 52)
                    if secure { reveal.resizable().frame(width: 44, height: 52) }
                }.padding(.horizontal, 16)
            }.frame(height: max(52, input.font!.lineHeight + 24))
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Account field") { QuickLayoutHostingController { AccountField(key: "account.design.password", secure: true, identifier: "preview").padding(24) } }
#endif
