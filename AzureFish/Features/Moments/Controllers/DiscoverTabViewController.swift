import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 系统标签中的发现容器；独立承载导航栈，避免 iPad 标签栏接管内层导航项目。
final class DiscoverTabViewController: UIViewController {
    private let navigation: AppNavigationController
    override var childForStatusBarStyle: UIViewController? { navigation }
    init(runtime: MomentsRuntime) {
        navigation = AppNavigationController(rootViewController: DiscoverViewController(runtime: runtime))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); addChild(navigation); view.addSubview(navigation.view)
        // UIKit 容器边界使用 Auto Layout，内容页面仍由 QuickLayout 管理。
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            navigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), navigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navigation.view.topAnchor.constraint(equalTo: view.topAnchor), navigation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigation.didMove(toParent: self)
    }
}


#if DEBUG
@available(iOS 17.0, *)
#Preview("发现标签容器") { DiscoverTabViewController(runtime: MomentsPreviewData.runtime()) }
#endif
