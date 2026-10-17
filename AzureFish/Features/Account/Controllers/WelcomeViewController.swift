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

#if DEBUG
@available(iOS 17.0, *)
#Preview("Welcome · 方案 2") { AppNavigationController(rootViewController: WelcomeViewController(session: .configured())) }
#endif
