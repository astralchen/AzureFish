import AzureFishAPI
import UIKit
import QuickLayoutKit

/// 敏感操作表单保留失败输入，仅在服务器确认后改变登录状态。
final class AccountSecurityActionViewController: AccountScreen, UITextFieldDelegate {
    private let session: SessionCoordinator
    private let runtime: ChatRuntime?
    private let action: AccountSecurityAction
    private let password = AccountField(key: "account.security.currentPassword", secure: true, identifier: "security.password")
    private let newPassword = AccountField(key: "account.security.newPassword", secure: true, identifier: "security.newPassword")
    private let confirmation = AccountField(key: "account.design.confirmPassword", secure: true, identifier: "security.confirm")
    private var submit: UIButton!
    private let feedback = UILabel()
    private var task: Task<Void, Never>?
    private var feedbackKey: String?
    override var localizedTitleKey: String? {
        switch action { case .changePassword: "account.design.changePassword"; case .logoutAll: "account.design.signOutAll"; case .deleteAccount: "account.design.deleteAccount" }
    }
    init(session: SessionCoordinator, runtime: ChatRuntime?, action: AccountSecurityAction) {
        self.session = session; self.runtime = runtime; self.action = action
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        password.input.textContentType = .password; newPassword.input.textContentType = .newPassword
        confirmation.input.textContentType = .newPassword
        [password, newPassword, confirmation].forEach { $0.input.delegate = self }
        password.input.returnKeyType = action == .changePassword ? .next : .done
        newPassword.input.returnKeyType = .next; confirmation.input.returnKeyType = .done
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .body); feedback.adjustsFontForContentSizeCategory = true
        content = [label(action == .deleteAccount ? "account.security.deleteHelp" : "account.security.logoutHelp", secondary: true), password]
        if action == .changePassword { content += [newPassword, confirmation, label("account.design.passwordRule", style: .footnote, secondary: true)] }
        content.append(feedback)
        submit = button(localizedTitleKey!, primary: true, destructive: action == .deleteAccount) { [weak self] in self?.confirm() }
        actions = [submit]
        if action == .deleteAccount { loadGroups() }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if isViewLoaded, action == .deleteAccount, task == nil { loadGroups() } }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); [password, newPassword, confirmation].forEach { $0.reloadText() }
        feedback.text = feedbackKey.map { Localization.text($0) }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === password.input, action == .changePassword { newPassword.input.becomeFirstResponder() }
        else if textField === newPassword.input { confirmation.input.becomeFirstResponder() }
        else { textField.resignFirstResponder() }
        return false
    }
    private func loadGroups() {
        guard task == nil else { return }
        submit.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }; defer { task = nil }
            do {
                let info = try await session.securityInfo()
                actions = [submit]; submit.isEnabled = info.ownedGroups.isEmpty
                setFeedback(info.ownedGroups.isEmpty ? nil : "account.security.ownedGroups")
                for group in info.ownedGroups {
                    let button = UIButton(type: .system); button.setTitle(group.title, for: .normal)
                    button.titleLabel?.numberOfLines = 0; button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                    button.addAction(UIAction { [weak self] _ in
                        guard let self, let runtime else { return }
                        navigationController?.pushViewController(ConversationDetailsViewController(runtime: runtime, conversation: group), animated: true)
                    }, for: .touchUpInside)
                    actions.append(button)
                }
            } catch {
                setFeedback(AccountFailure.key(for: error))
                actions = [button("account.design.retry") { [weak self] in self?.loadGroups() }]
            }
            setNeedsQuickLayout()
        }
    }
    private func confirm() {
        guard task == nil else { return }
        guard AccountValidation.password(password.input.text ?? "") else { setFeedback("account.design.passwordRule"); return }
        if action == .changePassword {
            guard AccountValidation.password(newPassword.input.text ?? "") else { setFeedback("account.design.passwordRule"); return }
            guard newPassword.input.text == confirmation.input.text else { setFeedback("account.design.mismatch"); return }
        }
        let alert = UIAlertController(title: Localization.text(localizedTitleKey!), message: Localization.text(action == .deleteAccount ? "account.security.deleteHelp" : "account.security.logoutHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text(localizedTitleKey!), style: .destructive) { [weak self] _ in self?.send() })
        present(alert, animated: true)
    }
    private func send() {
        guard task == nil else { return }
        submit.isEnabled = false; submit.configuration?.showsActivityIndicator = true
        [password, newPassword, confirmation].forEach { $0.input.isEnabled = false }
        navigationItem.hidesBackButton = true; navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil; submit.isEnabled = true; submit.configuration?.showsActivityIndicator = false
                [password, newPassword, confirmation].forEach { $0.input.isEnabled = true }
                navigationItem.hidesBackButton = false; navigationController?.interactivePopGestureRecognizer?.isEnabled = true
            }
            do { try await session.performSecurity(action, password: password.input.text ?? "", newPassword: newPassword.input.text ?? "") }
            catch { setFeedback(AccountFailure.key(for: error)) }
        }
    }
    private func setFeedback(_ key: String?) {
        feedbackKey = key; feedback.text = key.map { Localization.text($0) }; setNeedsQuickLayout()
        if let text = feedback.text { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("修改密码") { UINavigationController(rootViewController: AccountSecurityActionViewController(session: .configured(), runtime: nil, action: .changePassword)) }
#endif
