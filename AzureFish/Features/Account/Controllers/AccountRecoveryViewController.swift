import UIKit
import QuickLayoutKit
import QuickLayout
import ListKit
import AppLocalization

/// 会话恢复页不显示旧账号内容；原数据不可读时允许重试和查看恢复说明。
final class AccountRecoveryViewController: AccountScreen {
    private let session: SessionCoordinator
    private let feedback = UILabel()
    init(session: SessionCoordinator) { self.session = session; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .body); feedback.adjustsFontForContentSizeCategory = true
        content = [label("account.brand", style: .title1), feedback]
        actions = [button("account.design.retry", primary: true) { [weak self] in
            guard let self else { return }; Task { await self.session.restore(); self.reloadLocalizedContent() }
        }, button("account.design.recovery") { [weak self] in self?.showMessage("account.design.recoveryHelp") },
        button("account.design.localLogout", destructive: true) { [weak self] in self?.confirmLocalLogout() }]
        reloadLocalizedContent()
    }
    private func confirmLocalLogout() {
        let alert = UIAlertController(title: Localization.text("account.design.localLogout"),
            message: Localization.text("account.design.logoutOffline"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: Localization.text("account.design.localLogout"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do { try await self.session.logout(localOnly: true) }
                catch { self.showMessage(AccountFailure.key(for: error)) }
            }
        })
        present(alert, animated: true)
    }
    override func reloadLocalizedContent() {
        super.reloadLocalizedContent()
        feedback.text = Localization.text(session.noticeKey ?? "account.design.loading")
        actions.forEach { $0.isHidden = session.phase == .restoring }
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("Recovery") { AccountRecoveryViewController(session: .configured()) }
#endif
