import UIKit

/// 非编辑、非滚动的消息正文，保留系统数据识别、文字选择和上下文菜单。
final class MessageBodyTextView: UITextView, UITextViewDelegate {
    var usesMessageMenu = false
    private(set) var isSelectingMessageText = false
    private var selectionMenu: UIInteraction?

    func beginMessageSelection() {
        guard !text.isEmpty else { return }
        isSelectingMessageText = true
        becomeFirstResponder()
        selectAll(nil)
        if #available(iOS 16.0, *) {
            let menu = (selectionMenu as? UIEditMenuInteraction) ?? UIEditMenuInteraction(delegate: nil)
            if selectionMenu == nil { selectionMenu = menu; addInteraction(menu) }
            menu.presentEditMenu(with: .init(identifier: nil,
                sourcePoint: CGPoint(x: bounds.midX, y: min(bounds.midY, 24))))
        }
    }

    func endMessageSelection() {
        guard isSelectingMessageText else { return }
        isSelectingMessageText = false
        if #available(iOS 16.0, *) { (selectionMenu as? UIEditMenuInteraction)?.dismissMenu() }
        selectedTextRange = nil
        _ = resignFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned && isSelectingMessageText {
            isSelectingMessageText = false
            selectedTextRange = nil
            if #available(iOS 16.0, *) { (selectionMenu as? UIEditMenuInteraction)?.dismissMenu() }
        }
        return resigned
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if usesMessageMenu && !isSelectingMessageText {
            if gestureRecognizer is UILongPressGestureRecognizer { return false }
            if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem,
                  defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        usesMessageMenu && !isSelectingMessageText ? nil : .init(menu: defaultMenu)
    }

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        dataDetectorTypes = [.phoneNumber, .link, .address, .calendarEvent, .flightNumber, .shipmentTrackingNumber]
        if #available(iOS 16.0, *) {
            dataDetectorTypes.formUnion([.money, .physicalValue])
        }
        accessibilityIdentifier = "imessage.message.text"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// UITextView 默认占满建议宽度；正文按内容收窄，长文本才换行。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard let attributedText, attributedText.length > 0 else { return .zero }
        let width = max(1, size.width)
        let bounds = attributedText.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let fittingWidth = min(width, ceil(bounds.width))
        let fitting = super.sizeThatFits(CGSize(width: fittingWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: fittingWidth, height: ceil(fitting.height))
    }
}
