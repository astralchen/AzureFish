#if DEBUG
import UIKit

/// UI 回归专用入口，用于验证聊天页退出、再次进入及草稿恢复。
/// 仅在显式传入测试启动参数时使用，正常启动直接进入聊天页。
@available(iOS 26.0, *)
final class ChatRegressionLaunchController: UICollectionViewController {
    /// 创建包含一个聊天入口的系统列表。
    init() {
        let configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    /// 此控制器仅支持代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 注册可供既有 UI 测试定位的列表单元格。
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AzureFish"
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "chat")
    }

    /// 测试入口列表始终只包含一条会话。
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }

    /// 配置聊天入口名称和稳定的辅助功能标识。
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "chat", for: indexPath) as! UICollectionViewListCell
        var content = cell.defaultContentConfiguration()
        content.text = Localization.text("demo.imessage.title")
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "demo.imessage.title"
        cell.accessories = [.disclosureIndicator()]
        return cell
    }

    /// 每次进入都创建独立页面，以覆盖页面释放和草稿重新加载。
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        navigationController?.pushViewController(ChatViewController(), animated: true)
    }
}
#endif
