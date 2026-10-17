import UIKit

/// 独立短视频标签容器；保持导航栈和播放位置，切换标签时由页面停止播放。
final class ShortVideoTabViewController: UIViewController {
    private let navigation: AppNavigationController
    override var childForStatusBarStyle: UIViewController? { navigation }
    #if DEBUG
    /// 固定数据入口替换导航根页后，继续持有其隔离存储所有者。
    var fixtureOwner: UIViewController?
    #endif
    convenience init(runtime: ShortVideoRuntime) {
        self.init(root: ShortVideoViewController(runtime: runtime))
    }
    init(root: UIViewController) {
        navigation = AppNavigationController(rootViewController: root)
        super.init(nibName: nil, bundle: nil)
        // 只覆盖视频标签的颜色；系统仍负责 26+ 的玻璃及 iPad 标签布局。
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundColor = UIColor.black.withAlphaComponent(0.9)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = .lightGray
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor.lightGray]
            layout.selected.iconColor = .white
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
        }
        tabBarItem.standardAppearance = appearance; tabBarItem.scrollEdgeAppearance = appearance
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); addChild(navigation); view.addSubview(navigation.view)
        // 与发现及聊天容器一致，UIKit 托管边界使用 Auto Layout，页面布局交给 QuickLayout。
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
#Preview("短视频标签") { ShortVideoTabViewController(runtime: ShortVideoRuntime()) }
#endif
