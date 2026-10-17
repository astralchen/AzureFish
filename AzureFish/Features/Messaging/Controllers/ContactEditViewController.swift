import AzureFishAPI
import AzureFishChat
import QuickLayout
import QuickLayoutKit
import UIKit

/// 备注和申请留言编辑页；语言及关系刷新不替换输入内容。
final class ContactEditViewController: ContactFormController {
    private let runtime: ChatRuntime
    private var contact: ChatContact
    private let operation: ContactAction
    private let input: AccountField
    init(runtime: ChatRuntime, contact: ChatContact, action: ContactAction) {
        self.runtime = runtime; self.contact = contact; self.operation = action
        input = AccountField(key: action == .remark ? "contacts.remark" : "contacts.message", identifier: "contacts.editor")
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var localizedTitleKey: String? { operation == .remark ? "contacts.remark" : "chat.live.request" }
    override func viewDidLoad() {
        super.viewDidLoad(); input.input.text = operation == .remark ? contact.remark : ""
        input.input.addAction(UIAction { [weak self] _ in self?.statusKey = nil }, for: .editingChanged)
        reloadLocalizedContent()
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); guard isViewLoaded else { return }; input.reloadText()
        fields = [text(contact.displayName, style: .title2), input,
                  text(Localization.text(operation == .remark ? "contacts.remarkHelp" : "contacts.messageHelp"), style: .footnote)]
        controls = [action(operation == .remark ? "contacts.save" : "chat.live.request", primary: true) { [weak self] in self?.save() }]
        updateBusy(); setNeedsQuickLayout()
    }
    override func updateBusy() { super.updateBusy(); input.input.isEnabled = !busy }
    private func save() {
        guard !busy, let engine = runtime.engine else { return }
        let value = input.input.text ?? ""
        guard value.count <= (operation == .remark ? 64 : 200),
              (value.isEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }) else {
            statusKey = "contacts.invalidInput"; setNeedsQuickLayout(); return
        }
        busy = true
        Task { [weak self] in
            guard let self else { return }; defer { busy = false }
            do {
                contact = try await runtime.contactOperations.mutate(contact, action: operation,
                    remark: operation == .remark ? value : "", message: operation == .request ? value : "")
                guard runtime.engine === engine, navigationController?.topViewController === self else { return }
                input.input.resignFirstResponder(); navigationController?.popViewController(animated: true)
            } catch {
                guard runtime.engine === engine else { return }
                if let fresh = runtime.contacts.first(where: { $0.peer.id == contact.peer.id }) { contact = fresh }
                report(error)
            }
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("备注编辑") { ContactEditViewController(runtime: ChatRuntime(session: .configured()), contact: ConversationPreviewData.contact, action: .remark) }
#endif
