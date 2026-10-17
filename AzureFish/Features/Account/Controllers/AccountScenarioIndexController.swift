#if DEBUG
import UIKit
import QuickLayoutKit
import QuickLayout

final class AccountScenarioIndexController: AccountScreen {
    override func viewDidLoad() {
        super.viewDidLoad()
        content = [label("account.debug.only", style: .title2)]
        for scenario in AccountDebugScenario.all {
            let button = UIButton(type: .system); button.setTitle(scenario.id, for: .normal)
            var config = UIButton.Configuration.plain(); config.contentInsets = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
            button.configuration = config
            button.addAction(UIAction { [weak self] _ in self?.navigationController?.pushViewController(scenario.makeController(), animated: true) }, for: .touchUpInside)
            content.append(button)
        }
        setNeedsQuickLayout()
    }
}

@available(iOS 17.0, *)
#Preview("Debug states") { AppNavigationController(rootViewController: AccountScenarioIndexController()) }
#endif
