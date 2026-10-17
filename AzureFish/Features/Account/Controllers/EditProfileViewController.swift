import UIKit
import QuickLayout
import QuickLayoutKit

/// 版本化资料草稿；冲突时保留编辑，展示最新资料后由用户确认新的版本依据。
final class EditProfileViewController: AccountScreen {
    var didFinish: (() -> Void)?
    private func finish() { if let didFinish { didFinish() } else { navigationController?.popViewController(animated: true) } }
    private let session: SessionCoordinator
    private var base: AccountProfile
    private let nickname = AccountField(key: "account.design.nickname", identifier: "account.profile.nickname")
    private let bio = ProfileBioTextView()
    private var avatarEditor: AvatarEditorCoordinator?
    private weak var avatarButton: UIButton?
    private var save: UIButton!
    private let feedback = UILabel()
    private var feedbackKey: String?
    private var task: Task<Void, Never>?
    private var sessionObservation: UUID?
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
        let avatar = AccountAvatarView()
        avatar.configure(session: session, user: base.userID, asset: session.profile?.avatarID)
        avatar.tintColor = .label; avatar.contentMode = .scaleAspectFit
        avatar.isAccessibilityElement = true
        let photoButton = button("account.design.changePhoto") { [weak self, weak avatar] in
            guard let self else { return }
            let editor = AvatarEditorCoordinator(host: self, session: session) { [weak self, weak avatar] in
                guard let self, let profile = session.profile else { return }
                // 头像独立提交只推进版本依据，不覆盖未提交的文字草稿。
                base = profile
                avatar?.configure(session: session, user: profile.userID, asset: profile.avatarID)
            }
            avatarEditor = editor; editor.choose(from: avatarButton ?? view)
        }
        avatarButton = photoButton
        let photoRow = QuickLayoutView { HStack(spacing: 16) { avatar.resizable().frame(width: 72, height: 72); photoButton } }
        content = [photoRow,
                   label("account.avatar.help", style: .footnote, secondary: true), nickname,
                   label("account.design.nicknameRule", style: .footnote, secondary: true),
                   label("account.design.bio", style: .footnote, secondary: true), bioHost,
                   label("account.design.bioRule", style: .footnote, secondary: true), feedback]
        if session.readOnly { content.append(label("account.design.offlineProfile", secondary: true)) }
        save = button("account.design.save", primary: true) { [weak self] in self?.send() }
        save.isEnabled = !session.readOnly; actions = [save]
        // 会话原位恢复只更新提交能力，不重建表单或覆盖草稿。
        sessionObservation = session.observe { [weak self] in
            guard let self else { return }
            save?.isEnabled = task == nil && !session.readOnly
        }
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Localization.text("account.design.cancel"), primaryAction: UIAction { [weak self] _ in self?.cancel() })
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        reloadLocalizedContent(); setNeedsQuickLayout()
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); navigationController?.interactivePopGestureRecognizer?.isEnabled = true }
    deinit {
        let session = session, observation = sessionObservation
        if let observation { Task { @MainActor in session.removeObserver(observation) } }
    }
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
                if let notice = session.noticeKey { setFeedback(notice) }
                else { finish() }
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
        guard nickname.input.text != base.nickname || bio.text != base.bio else { finish(); return }
        let alert = UIAlertController(title: Localization.text("account.design.discard"), message: Localization.text("account.design.discardHelp"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.keepEditing"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.discard"), style: .destructive) { [weak self] _ in self?.finish() })
        present(alert, animated: true)
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Edit profile") { AppNavigationController(rootViewController: EditProfileViewController(session: .configured(), profile: AccountProfile(userID: UUID(), accountName: "azure_fish", nickname: "小鱼", bio: "", version: 1))) }
@available(iOS 17.0, *)
#Preview("Long profile") { AppNavigationController(rootViewController: EditProfileViewController(session: .configured(), profile: AccountProfile(userID: UUID(), accountName: "azure_fish", nickname: "小鱼", bio: String(repeating: "A long profile. 個人資料。", count: 20), version: 1))) }
#endif
