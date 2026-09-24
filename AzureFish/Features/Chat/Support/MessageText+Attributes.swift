import UIKit

extension MessageText {
    /// 只接受四种文字格式，不把颜色、字体大小或编辑器附件带入消息模型。
    @MainActor
    init(attributedString: NSAttributedString) {
        var runs: [Run] = []
        attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length)) { attributes, range, _ in
            guard attributes[.attachment] == nil else { return }
            runs.append(Run((attributedString.string as NSString).substring(with: range),
                            style: Style(attributes: attributes)))
        }
        self.init(runs: runs)
    }

    @MainActor
    func attributedString(font: UIFont, color: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in runs {
            result.append(NSAttributedString(string: run.text, attributes: run.style.attributes(font: font, color: color)))
        }
        return result
    }
}

extension MessageText.Style {
    @MainActor
    init(attributes: [NSAttributedString.Key: Any]) {
        var style: Self = []
        let traits = (attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        if traits.contains(.traitBold) { style.insert(.bold) }
        if traits.contains(.traitItalic) { style.insert(.italic) }
        if (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { style.insert(.underline) }
        if (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { style.insert(.strikethrough) }
        self = style
    }

    @MainActor
    func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        var traits = font.fontDescriptor.symbolicTraits
        traits.remove([.traitBold, .traitItalic])
        if contains(.bold) { traits.insert(.traitBold) }
        if contains(.italic) { traits.insert(.traitItalic) }
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
        return [
            .font: UIFont(descriptor: descriptor, size: font.pointSize),
            .foregroundColor: color,
            .underlineStyle: contains(.underline) ? NSUnderlineStyle.single.rawValue : 0,
            .strikethroughStyle: contains(.strikethrough) ? NSUnderlineStyle.single.rawValue : 0,
        ]
    }
}
