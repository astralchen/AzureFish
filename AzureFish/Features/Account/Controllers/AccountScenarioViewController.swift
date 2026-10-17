#if DEBUG
import UIKit
import QuickLayoutKit
import QuickLayout

/// 可检查每个未开放动作的文案与共享输入／反馈样式，按钮只切换演示状态。
final class AccountScenarioViewController: AccountScreen {
    private let scenario: AccountDebugScenario
    init(scenario: AccountDebugScenario) { self.scenario = scenario; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        content = [label("account.debug.only", style: .footnote, secondary: true), label(scenario.titleKey, style: .title1)]
        let identifier = UILabel(); identifier.text = scenario.id; identifier.font = .preferredFont(forTextStyle: .caption1)
        content.append(identifier)
        let id = scenario.id
        if id.contains("Password") || id.hasPrefix("password.") || id.hasPrefix("reauth.") {
            content.append(AccountField(key: "account.design.newPassword", secure: true, identifier: "debug.password"))
            content.append(AccountField(key: "account.design.confirmPassword", secure: true, identifier: "debug.confirm"))
        } else if id.hasPrefix("edit.") || id == "nickname" || id == "bio" || id.hasPrefix("complete") {
            content.append(AccountField(key: "account.design.nickname", identifier: "debug.nickname"))
            content.append(AccountField(key: "account.design.bio", identifier: "debug.bio"))
        } else if id.hasPrefix("security.") || id.hasPrefix("methods.") {
            content += [label("account.design.passwordMethod"), label(id.contains("apple") ? "account.design.notSet" : "account.design.available"),
                        label("account.design.appleMethod"), label(id.contains("password") ? "account.design.unbound" : "account.design.bound")]
        } else if id.hasPrefix("avatar") {
            let photo = UIImageView(image: UIImage(systemName: "person.crop.square.fill")); photo.tintColor = .secondaryLabel
            photo.contentMode = .scaleAspectFit
            content.append(QuickLayoutView { photo.resizable().frame(width: 160, height: 160) })
            content.append(label("account.design.photoImmediate", style: .footnote, secondary: true))
        }
        content.append(label(scenario.messageKey, secondary: true))
        if id.contains("loading") || id.contains("processing") || id.contains("uploading") || id.contains("saving") {
            let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating(); content.append(progress)
        }
        actions = scenario.actions.map { key, destination in
            button(key, primary: true) { [weak self] in
                guard let next = AccountDebugScenario.all.first(where: { $0.id == destination }) else { return }
                self?.navigationController?.pushViewController(next.makeController(), animated: true)
            }
        }
        actions.append(button("account.design.cancel") { [weak self] in self?.navigationController?.popViewController(animated: true) })
        setNeedsQuickLayout()
    }
}

@available(iOS 17.0, *)
#Preview("Avatar failure · Debug") { AccountScenarioViewController(scenario: AccountDebugScenario.all.first { $0.id == "avatar.failed" }!) }
#endif
