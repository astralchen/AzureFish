import AzureFishAPI
import UIKit

/// 当前账号的预览图片缓存；按最近使用顺序限制解码成本，内存警告时释放。
@MainActor
final class MomentsPhotoCache {
    private struct Entry {
        let asset: ChatAsset
        let target: String
        let image: UIImage
        let cost: Int
    }
    private var entries: [Entry] = []
    private let countLimit: Int
    private let costLimit: Int
    private var warning: NSObjectProtocol?

    /// 创建仅驻留内存的缓存；countLimit 为图片数，costLimit 为估计解码字节数。
    init(countLimit: Int = 9, costLimit: Int = 96 * 1024 * 1024) {
        self.countLimit = max(0, countLimit); self.costLimit = max(0, costLimit)
        warning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }
    /// 按目标和完整资产描述命中图片，并将其移到最近使用位置；不执行权限请求。
    func image(for asset: ChatAsset, target: String) -> UIImage? {
        guard let index = entries.firstIndex(where: { $0.target == target && $0.asset == asset }) else { return nil }
        let entry = entries.remove(at: index); entries.append(entry)
        return entry.image
    }
    /// 替换同目标下的同 ID 图片，再按最近使用顺序淘汰超额项；单图超限时不缓存。
    func insert(_ image: UIImage, asset: ChatAsset, target: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        guard countLimit > 0, cost <= costLimit else { return }
        entries.removeAll { $0.target == target && $0.asset.id == asset.id }
        entries.append(Entry(asset: asset, target: target, image: image, cost: cost))
        var total = entries.reduce(0) { $0 + $1.cost }
        while entries.count > countLimit || total > costLimit { total -= entries.removeFirst().cost }
    }
    func removeUnreferenced(_ isReferenced: (ChatAsset, String) -> Bool) {
        entries.removeAll { !isReferenced($0.asset, $0.target) }
    }
    func remove(target: String) { entries.removeAll { $0.target == target } }
    func removeAll() { entries = [] }
    isolated deinit { if let warning { NotificationCenter.default.removeObserver(warning) } }
}
