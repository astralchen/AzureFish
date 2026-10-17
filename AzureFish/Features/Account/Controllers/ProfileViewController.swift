import UIKit
import QuickLayout
import QuickLayoutKit

/// 个人中心按容器宽度展开双列，窄屏保留同一资料状态。
final class ProfileViewController: AccountScreen {
    var openDetail: ((UIViewController) -> Void)?
    var showsMenu = true
    private let runtime: ChatRuntime?
    private var observation: UUID?
    private let session: SessionCoordinator
    private let name = UILabel()
    private let account = UILabel()
    private let bio = UILabel()
    private let notice = UILabel()
    private let avatar = AccountAvatarView()
    private let menu = ProfileMenuView()
    override var localizedTitleKey: String? { "account.design.me" }
    init(session: SessionCoordinator, runtime: ChatRuntime? = nil) { self.runtime = runtime; self.session = session; super.init(nibName: nil, bundle: nil); grouped = true; maximumWidth = 600 }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        setContentScrollView(scroll, for: .top)
        name.font = .preferredFont(forTextStyle: .title2); account.font = .preferredFont(forTextStyle: .footnote)
        bio.font = .preferredFont(forTextStyle: .body); notice.font = .preferredFont(forTextStyle: .footnote)
        for label in [name, account, bio, notice] { label.numberOfLines = 0; label.adjustsFontForContentSizeCategory = true }
        account.textColor = .secondaryLabel; bio.textColor = .secondaryLabel; notice.textColor = .secondaryLabel
        account.semanticContentAttribute = .forceLeftToRight
        avatar.tintColor = .label; avatar.contentMode = .scaleAspectFit
        avatar.isAccessibilityElement = true
        menu.didSelect = { [weak self] key in
            guard let self else { return }
            switch key {
            case "account.design.editProfile": self.edit()
            case "moments.album": if let runtime = self.runtime { self.open(MomentsViewController(runtime: runtime.moments, author: runtime.userID)) }
            case "account.design.security": self.openSecurity()
            case "account.design.settings": self.open(AccountSettingsViewController(runtime: self.runtime))
            case "account.design.reload": self.reloadProfile()
            case "account.design.signOut": self.confirmLogout()
            default: break
            }
        }
        menu.heightDidChange = { [weak self] in self?.setNeedsQuickLayout() }
        observation = runtime?.observe { [weak self] in self?.refresh() }
        refresh(); setNeedsQuickLayout()
    }
    override var body: Layout {
        ScrollView(scroll) {
            VStack(alignment: .leading, spacing: 24) {
                summary
                if showsMenu { menu.resizable(axis: .horizontal) }
            }.frame(width: min(600, max(0, view.bounds.width - 48))).padding(.vertical, 16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaPadding(.all, 0)
    }
    private var summary: Layout {
        VStack(alignment: .leading, spacing: 12) {
            avatar.resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) { name; account }
            if !(bio.text ?? "").isEmpty { bio }
            if !(notice.text ?? "").isEmpty { notice }
        }
    }
    private func reloadProfile() {
        guard !menu.isReloading else { return }
        menu.isReloading = true
        Task { [weak self] in
            guard let self else { return }
            defer { menu.isReloading = false }
            do {
                if session.readOnly { await session.restore() }
                else { try await session.reloadProfile() }
                refresh()
            }
            catch { showMessage(AccountFailure.key(for: error)) }
        }
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); refresh() }
    override func reloadLocalizedContent() { super.reloadLocalizedContent(); refresh() }
    private func refresh() {
        guard isViewLoaded else { return }
        name.text = session.profile?.nickname
        account.text = session.profile.map { "@" + $0.accountName }
        bio.text = session.profile?.bio
        notice.text = session.readOnly ? Localization.text(session.connectivity == .checking ? "account.connection.checking" : "account.connection.offline") : session.noticeKey.map { Localization.text($0) } ?? ((session.profile?.bio.isEmpty == true) ? Localization.text("account.design.incomplete") : nil)
        if let profile = session.profile { avatar.configure(session: session, user: profile.userID, asset: profile.avatarID) }
        for label in [name, account, bio, notice] {
            label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        }
        menu.reloadContent()
        setNeedsQuickLayout()
    }
    private func edit() {
        guard let profile = session.profile else { return }
        open(EditProfileViewController(session: session, profile: profile))
    }
    deinit {
        if let observation, let runtime { Task { @MainActor in runtime.remove(observation) } }
    }
    private func open(_ controller: UIViewController) {
        if let openDetail { openDetail(controller) }
        else { navigationController?.pushViewController(controller, animated: true) }
    }
    private func openSecurity() {
        open(AccountSecurityViewController(session: session, runtime: runtime))
    }
    private func confirmLogout() {
        let alert = UIAlertController(title: Localization.text("account.design.signOut"), message: Localization.text("account.design.logoutHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.signOut"), style: .destructive) { [weak self] _ in self?.logout() })
        present(alert, animated: true)
    }
    private func logout(localOnly: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            do { try await session.logout(localOnly: localOnly) }
            catch {
                let alert = UIAlertController(title: Localization.text(AccountFailure.key(for: error)), message: Localization.text("account.design.logoutOffline"), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
                alert.addAction(UIAlertAction(title: Localization.text("account.design.retry"), style: .default) { [weak self] _ in self?.logout(localOnly: localOnly) })
                if !localOnly { alert.addAction(UIAlertAction(title: Localization.text("account.design.localLogout"), style: .destructive) { [weak self] _ in self?.logout(localOnly: true) }) }
                present(alert, animated: true)
            }
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Me") { AppNavigationController(rootViewController: ProfileViewController(session: .configured())) }
#endif
