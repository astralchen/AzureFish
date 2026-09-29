import UIKit
import QuickLayoutKit
import QuickLayout

/// 顶部标题方向的欢迎页，系统菜单与安装级偏好共享状态。
final class WelcomeViewController: AccountScreen {
    let session: SessionCoordinator
    init(session: SessionCoordinator) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let brand = label("account.brand", style: .title2); brand.textColor = .systemBlue
        let whale = UIImageView(image: UIImage(named: "BrandWhale")); whale.contentMode = .scaleAspectFit
        whale.semanticContentAttribute = .forceLeftToRight
        whale.layer.cornerRadius = 8; whale.clipsToBounds = true
        let brandRow = QuickLayoutView { HStack(spacing: 8) { whale.resizable().frame(width: 40, height: 40); brand }.frame(maxWidth: .infinity, alignment: .leading) }
        content = [brandRow, label("account.design.welcome", style: .largeTitle), label("account.design.tagline", secondary: true)]
        if session.service == nil { content.append(label("account.unavailable", style: .footnote, secondary: true)) }
        else if let notice = session.noticeKey { content.append(label(notice, style: .footnote, secondary: true)) }
        actions = [button("account.design.accountLogin", primary: true) { [weak self] in self?.open(register: false) },
                   button("account.design.register") { [weak self] in self?.open(register: true) }]
        settingsMenus(); setNeedsQuickLayout()
    }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); settingsMenus() }
    private func open(register: Bool) {
        navigationController?.pushViewController(AuthenticationViewController(session: session, register: register), animated: true)
    }
}

/// 密码认证表单；提交后保留同一操作直到成功、改动输入或明确放弃。
final class AuthenticationViewController: AccountScreen {
    private let session: SessionCoordinator
    private let register: Bool
    private let remembered: RememberedLoginAccount?
    private let account = AccountField(key: "account.design.account", identifier: "account.input.name")
    private let password = AccountField(key: "account.design.password", secure: true, identifier: "account.input.password")
    private let confirmation = AccountField(key: "account.design.confirmPassword", secure: true, identifier: "account.input.confirm")
    private let nickname = AccountField(key: "account.design.nickname", identifier: "account.input.nickname")
    private let feedback = UILabel()
    private var feedbackKey: String?
    private var submit: UIButton!
    private var task: Task<Void, Never>?
    init(session: SessionCoordinator, register: Bool, remembered: RememberedLoginAccount? = nil) {
        self.session = session; self.register = register; self.remembered = remembered
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        account.input.textContentType = .username; account.input.autocapitalizationType = .none
        account.input.keyboardType = .asciiCapable; account.input.semanticContentAttribute = .forceLeftToRight
        password.input.textContentType = register ? .newPassword : .password
        confirmation.input.textContentType = .newPassword
        nickname.input.textContentType = .nickname
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .footnote)
        feedback.adjustsFontForContentSizeCategory = true; feedback.textColor = .systemRed; feedback.textAlignment = .natural
        feedback.accessibilityIdentifier = "account.feedback"
        content = [label("account.design.\(register ? "register" : "login")", style: .title1),
                   label("account.design.\(register ? "registerHelp" : "loginHelp")", secondary: true), account]
        if register { content.append(label("account.design.accountRule", style: .footnote, secondary: true)) }
        if let remembered {
            account.input.text = remembered.accountName
            account.input.isEnabled = false
        }
        if register { content += [nickname, label("account.design.nicknameRule", style: .footnote, secondary: true)] }
        content.append(password)
        if register {
            content += [label("account.design.passwordRule", style: .footnote, secondary: true), confirmation]
        }
        content.append(feedback)
        submit = button("account.design.\(register ? "register" : "signIn")", primary: true) { [weak self] in self?.send() }
        actions = [submit]
        if !register {
            if remembered != nil {
                actions.append(button("account.login.other") { [weak self] in
                    self?.discardThen { [weak self] in self?.openForm(register: false) }
                })
            }
            actions.append(button("account.design.register") { [weak self] in
                self?.discardThen { [weak self] in self?.openForm(register: true) }
            })
        }
        let fields = register ? [account, nickname, password, confirmation] : remembered == nil ? [account, password] : [password]
        for (index, field) in fields.enumerated() {
            field.input.returnKeyType = index == fields.count - 1 ? .go : .next
            let next = index + 1 < fields.count ? fields[index + 1].input : nil
            field.input.addAction(UIAction { [weak self, weak next] _ in
                if let next { next.becomeFirstResponder() }
                else { self?.send() }
            }, for: .editingDidEndOnExit)
        }
        settingsMenus()
        if let notice = session.noticeKey { showFeedback(notice) }
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Localization.text("account.design.cancel"), primaryAction: UIAction { [weak self] _ in self?.cancel() })
        if remembered != nil { navigationItem.leftBarButtonItem = nil }
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        setNeedsQuickLayout()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        settingsMenus()
        [account, password, confirmation, nickname].forEach { $0.reloadText() }
        #if DEBUG
        if navigationItem.prompt != nil { navigationItem.prompt = Localization.text("account.debug.only") }
        #endif
        feedback.text = feedbackKey.map { Localization.text($0) }
        navigationItem.leftBarButtonItem?.title = Localization.text("account.design.cancel")
    }
    private func send() {
        guard task == nil else { return }
        let input = AuthenticationInput(register: register, account: account.input.text ?? "", password: password.input.text ?? "", nickname: nickname.input.text ?? "")
        let errorKey: String?
        if !AccountValidation.account(input.account) { errorKey = "account.design.accountRule" }
        else if !AccountValidation.password(input.password) { errorKey = "account.design.passwordRule" }
        else if register && input.password != confirmation.input.text { errorKey = "account.design.mismatch" }
        else if register && !AccountValidation.nickname(input.nickname) { errorKey = "account.design.nicknameRule" }
        else { errorKey = nil }
        if let errorKey {
            showFeedback(errorKey)
            let field = errorKey == "account.design.accountRule" ? account : errorKey == "account.design.nicknameRule" ? nickname : errorKey == "account.design.mismatch" ? confirmation : password
            field.input.becomeFirstResponder()
            return
        }
        submit.isEnabled = false; submit.configuration?.showsActivityIndicator = true
        [account, password, confirmation, nickname].forEach { $0.input.isEnabled = false }
        showFeedback(nil)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil; self.submit.isEnabled = true; self.submit.configuration?.showsActivityIndicator = false
                [self.account, self.password, self.confirmation, self.nickname].forEach { $0.input.isEnabled = true }
                self.account.input.isEnabled = self.remembered == nil
            }
            do {
                try await self.session.authenticate(input)
                self.password.input.text = nil; self.confirmation.input.text = nil
            }
            catch { self.showFeedback(AccountFailure.key(for: error)) }
        }
    }
    private func showFeedback(_ key: String?) {
        feedbackKey = key; feedback.text = key.map { Localization.text($0) }; setNeedsQuickLayout()
        if let text = feedback.text { UIAccessibility.post(notification: .announcement, argument: text) }
    }
    #if DEBUG
    func applyDebugState(_ id: String) {
        navigationItem.prompt = Localization.text("account.debug.only")
        if !id.hasSuffix("empty") {
            account.input.text = "fictional_user"; password.input.text = "Fictional-Password-123"
            nickname.input.text = "Fictional"
        }
        let keys = ["error": "loginError", "offline": "offline", "timeout": "timeout", "mismatch": "mismatch", "taken": "taken"]
        if let suffix = id.split(separator: ".").last, let key = keys[String(suffix)] { showFeedback("account.design." + key) }
        if id.hasSuffix("passwordVisible") { password.input.isSecureTextEntry = false; password.reloadText() }
        if id.hasSuffix("loading") { submit.isEnabled = false; submit.configuration?.showsActivityIndicator = true }
    }
    #endif

    private func openForm(register: Bool) {
        navigationController?.pushViewController(AuthenticationViewController(session: session, register: register), animated: true)
    }
    private func cancel() {
        discardThen { [weak self] in self?.navigationController?.popViewController(animated: true) }
    }
    private func discardThen(_ action: @escaping () -> Void) {
        let fields = remembered == nil ? [account, password, confirmation, nickname] : [password]
        let changed = fields.contains { !($0.input.text ?? "").isEmpty }
        guard changed || task != nil else { action(); return }
        let alert = UIAlertController(title: Localization.text("account.design.discard"), message: Localization.text("account.cancel.auth"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.keepEditing"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.discard"), style: .destructive) { [weak self] _ in
            self?.task?.cancel(); self?.session.cancelAuthentication()
            self?.password.input.text = nil; self?.confirmation.input.text = nil
            action()
        })
        present(alert, animated: true)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Welcome · 方案 2") { UINavigationController(rootViewController: WelcomeViewController(session: .configured())) }
@available(iOS 17.0, *)
#Preview("Registration") { UINavigationController(rootViewController: AuthenticationViewController(session: .configured(), register: true)) }
#endif

#if DEBUG
@available(iOS 17.0, *)
#Preview("Remembered account") {
    UINavigationController(rootViewController: AuthenticationViewController(session: .configured(), register: false,
        remembered: .init(environmentID: "preview", userID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, accountName: "fictional_user")))
}
#endif
