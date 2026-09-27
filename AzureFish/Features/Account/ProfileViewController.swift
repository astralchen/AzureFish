import UIKit
import QuickLayout
import QuickLayoutKit

/// 个人中心按容器宽度展开双列，窄屏保留同一资料状态。
final class ProfileViewController: AccountScreen {
    private let session: SessionCoordinator
    private let name = UILabel()
    private let account = UILabel()
    private let bio = UILabel()
    private let notice = UILabel()
    private let avatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
    private let menu = ProfileMenuView()
    override var localizedTitleKey: String? { "account.design.me" }
    init(session: SessionCoordinator) { self.session = session; super.init(nibName: nil, bundle: nil); grouped = true; maximumWidth = 600 }
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
            case "account.design.security": self.openSecurity()
            case "account.design.settings": self.navigationController?.pushViewController(AccountSettingsViewController(), animated: true)
            case "account.design.reload": self.reloadProfile()
            case "account.design.signOut": self.confirmLogout()
            default: break
            }
        }
        menu.heightDidChange = { [weak self] in self?.setNeedsQuickLayout() }
        refresh(); setNeedsQuickLayout()
    }
    override var body: Layout {
        ScrollView(scroll) {
            if traitCollection.horizontalSizeClass == .regular && view.bounds.inset(by: view.safeAreaInsets).width >= 840 {
                HStack(alignment: .top, spacing: 32) {
                    summary.frame(width: 320)
                    menu.resizable(axis: .horizontal).frame(maxWidth: 600)
                }.padding(24)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    menu.resizable(axis: .horizontal)
                }.frame(width: min(600, max(0, view.bounds.width - 48))).padding(.vertical, 16)
            }
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
            do { try await session.reloadProfile(); refresh() }
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
        notice.text = session.readOnly ? Localization.text("account.design.offlineProfile") : session.noticeKey.map { Localization.text($0) } ?? ((session.profile?.bio.isEmpty == true) ? Localization.text("account.design.incomplete") : nil)
        avatar.accessibilityLabel = Localization.text("account.default.avatar")
        for label in [name, account, bio, notice] {
            label.textAlignment = Localization.currentUIKitDirection == .rightToLeft ? .right : .left
        }
        menu.reloadContent()
        setNeedsQuickLayout()
    }
    private func edit() {
        guard let profile = session.profile else { return }
        navigationController?.pushViewController(EditProfileViewController(session: session, profile: profile), animated: true)
    }
    private func openSecurity() {
        navigationController?.pushViewController(AccountSecurityViewController(session: session), animated: true)
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

/// 版本化资料草稿；冲突时保留编辑，展示最新资料后由用户确认新的版本依据。
final class EditProfileViewController: AccountScreen {
    private let session: SessionCoordinator
    private var base: AccountProfile
    private let nickname = AccountField(key: "account.design.nickname", identifier: "account.profile.nickname")
    private let bio = ProfileBioTextView()
    private var save: UIButton!
    private let feedback = UILabel()
    private var feedbackKey: String?
    private var task: Task<Void, Never>?
    override var localizedTitleKey: String? { "account.design.editProfile" }
    init(session: SessionCoordinator, profile: AccountProfile) {
        self.session = session; base = profile
        super.init(nibName: nil, bundle: nil); maximumWidth = 600
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        nickname.input.text = base.nickname
        bio.text = base.bio; bio.font = .preferredFont(forTextStyle: .body); bio.adjustsFontForContentSizeCategory = true
        bio.backgroundColor = .secondarySystemBackground; bio.layer.cornerRadius = 14
        bio.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        bio.isScrollEnabled = false; bio.accessibilityIdentifier = "account.profile.bio"
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .footnote); feedback.adjustsFontForContentSizeCategory = true
        let bioHost = QuickLayoutView { [bio] in bio.resizable(axis: .horizontal).frame(minHeight: 144) }
        let avatar = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
        avatar.tintColor = .label; avatar.contentMode = .scaleAspectFit
        avatar.isAccessibilityElement = true; avatar.accessibilityLabel = Localization.text("account.default.avatar")
        let photoButton = button("account.design.changePhoto") { [weak self] in self?.explainUnavailable() }
        let photoRow = QuickLayoutView { HStack(spacing: 16) { avatar.resizable().frame(width: 72, height: 72); photoButton } }
        content = [photoRow,
                   label("account.unavailable.feature", style: .footnote, secondary: true), nickname,
                   label("account.design.nicknameRule", style: .footnote, secondary: true),
                   label("account.design.bio", style: .footnote, secondary: true), bioHost,
                   label("account.design.bioRule", style: .footnote, secondary: true), feedback]
        if session.readOnly { content.append(label("account.design.offlineProfile", secondary: true)) }
        save = button("account.design.save", primary: true) { [weak self] in self?.send() }
        save.isEnabled = !session.readOnly; actions = [save]
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Localization.text("account.design.cancel"), primaryAction: UIAction { [weak self] _ in self?.cancel() })
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        reloadLocalizedContent(); setNeedsQuickLayout()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); navigationController?.interactivePopGestureRecognizer?.isEnabled = true }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent(); nickname.reloadText()
        bio.accessibilityLabel = Localization.text("account.design.bio")
        feedback.text = feedbackKey.map { Localization.text($0) }
        navigationItem.leftBarButtonItem?.title = Localization.text("account.design.cancel")
    }
    private func send() {
        guard task == nil else { return }
        let name = nickname.input.text ?? "", text = bio.text ?? ""
        guard AccountValidation.nickname(name), AccountValidation.bio(text) else { setFeedback("account.validation"); return }
        save.isEnabled = false; save.configuration?.showsActivityIndicator = true
        nickname.input.isEnabled = false; bio.isEditable = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil; save.isEnabled = !session.readOnly; save.configuration?.showsActivityIndicator = false
                nickname.input.isEnabled = true; bio.isEditable = true; navigationItem.leftBarButtonItem?.isEnabled = true
            }
            do {
                try await session.saveProfile(base: base, nickname: name, bio: text)
                if let latest = session.profile { base = latest }
                setFeedback(session.noticeKey ?? "account.design.saved")
            } catch AccountFailure.conflict { reviewConflict() }
            catch { setFeedback(AccountFailure.key(for: error)) }
        }
    }
    private func reviewConflict() {
        guard let latest = session.profile else { setFeedback("account.conflict"); return }
        let alert = UIAlertController(title: Localization.text("account.design.conflictTitle"),
            message: Localization.text("account.conflict.review", latest.nickname, latest.bio), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.reviewSave"), style: .default) { [weak self] _ in
            self?.base = latest; self?.setFeedback("account.conflict.confirmed")
        })
        present(alert, animated: true)
    }
    private func setFeedback(_ key: String) {
        feedbackKey = key; feedback.text = Localization.text(key); setNeedsQuickLayout()
        UIAccessibility.post(notification: .announcement, argument: feedback.text)
    }
    private func cancel() {
        guard task == nil else { return }
        guard nickname.input.text != base.nickname || bio.text != base.bio else { navigationController?.popViewController(animated: true); return }
        let alert = UIAlertController(title: Localization.text("account.design.discard"), message: Localization.text("account.design.discardHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.keepEditing"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.discard"), style: .destructive) { [weak self] _ in self?.navigationController?.popViewController(animated: true) })
        present(alert, animated: true)
    }
}

/// 在给定容器宽度内测量全部简介，滚动交由页面统一处理。
private final class ProfileBioTextView: UITextView {
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        // QuickLayout 对未重写此方法的 UITextView 直接采用建议尺寸，不能反映长文本高度。
        let width = size.width.isFinite && size.width > 0 ? size.width : max(1, bounds.width)
        let fitted = super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(144, ceil(fitted.height)))
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Me") { UINavigationController(rootViewController: ProfileViewController(session: .configured())) }
@available(iOS 17.0, *)
#Preview("Edit profile") { UINavigationController(rootViewController: EditProfileViewController(session: .configured(), profile: AccountProfile(userID: UUID(), accountName: "azure_fish", nickname: "小鱼", bio: "", version: 1))) }
@available(iOS 17.0, *)
#Preview("Long profile") { UINavigationController(rootViewController: EditProfileViewController(session: .configured(), profile: AccountProfile(userID: UUID(), accountName: "azure_fish", nickname: "小鱼", bio: String(repeating: "A long profile. 個人資料。", count: 20), version: 1))) }
#endif
