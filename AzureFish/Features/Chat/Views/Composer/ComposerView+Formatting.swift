import AppLocalization
import UIKit

@available(iOS 26.0, *)
extension ComposerView {
    /// 通过系统文字选区菜单设置格式；保留系统复制、粘贴及替换等动作。
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard !isShowingRecordingUnavailableHint, textView.markedTextRange == nil,
              range.length > 0, range.location != NSNotFound,
              NSMaxRange(range) <= textView.textStorage.length else {
            return UIMenu(children: suggestedActions)
        }
        let styles = selectedStyles(in: range)
        guard !styles.isEmpty else { return UIMenu(children: suggestedActions) }
        let formats: [(MessageText.Style, String, String)] = [
            (.bold, "bold", "bold"),
            (.italic, "italic", "italic"),
            (.underline, "underline", "underline"),
            (.strikethrough, "strikethrough", "strikethrough"),
        ]
        let actions = formats.map { style, key, symbol in
            UIAction(title: Localization.text("imessage.format.\(key)"), image: UIImage(systemName: symbol),
                     state: styles.allSatisfy { $0.contains(style) } ? .on : .off) { [weak self] _ in
                self?.toggleFormatting(style, range: range)
            }
        }
        return UIMenu(children: [UIMenu(title: Localization.text("imessage.format.title"), children: actions)] + suggestedActions)
    }

    /// 混合选区统一添加格式；只有全部文字已设置该格式时才取消，附件保持原样。
    func toggleFormatting(_ style: MessageText.Style, range: NSRange) {
        guard !isShowingRecordingUnavailableHint, textView.markedTextRange == nil,
              range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= textView.textStorage.length else { return }
        let styles = selectedStyles(in: range)
        guard !styles.isEmpty else { return }
        let remove = styles.allSatisfy { $0.contains(style) }
        let updated = NSMutableAttributedString(attributedString: textView.textStorage)
        updated.enumerateAttributes(in: range) { attributes, runRange, _ in
            guard attributes[.attachment] == nil, attributes[TextAttachment.separatorKey] == nil else { return }
            var value = MessageText.Style(attributes: attributes)
            if remove { value.remove(style) } else { value.insert(style) }
            updated.addAttributes(value.attributes(
                font: .preferredFont(forTextStyle: .body, compatibleWith: traitCollection), color: .label
            ), range: runRange)
        }
        applyFormatting(updated, selection: range)
    }

    private func selectedStyles(in range: NSRange) -> [MessageText.Style] {
        var result: [MessageText.Style] = []
        textView.textStorage.enumerateAttributes(in: range) { attributes, _, _ in
            if attributes[.attachment] == nil, attributes[TextAttachment.separatorKey] == nil {
                result.append(MessageText.Style(attributes: attributes))
            }
        }
        return result
    }

    /// 只替换属性，避免扰动 UITextInput 的字符上下文；撤销和重做使用同一入口。
    private func applyFormatting(_ value: NSAttributedString, selection: NSRange) {
        guard textView.textStorage.string == value.string else { return }
        let previous = NSAttributedString(attributedString: textView.textStorage)
        let previousSelection = textView.selectedRange
        textView.undoManager?.registerUndo(withTarget: self) { composer in
            composer.applyFormatting(previous, selection: previousSelection)
        }
        textView.textStorage.beginEditing()
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            textView.textStorage.setAttributes(attributes, range: range)
        }
        textView.textStorage.endEditing()
        textView.selectedRange = selection
        textViewDidChange(textView)
    }
}
