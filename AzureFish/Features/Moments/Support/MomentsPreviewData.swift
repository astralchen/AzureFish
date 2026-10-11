import AzureFishAPI
import UIKit

#if DEBUG
@MainActor enum MomentsPreviewData {
    static let user = ChatUser(id: "00000000-0000-0000-0000-000000000001", nickname: "陈晨", version: 1, avatarID: nil, deleted: false)
    static let posts = [MomentsPost(id: "00000000-0000-0000-0000-000000000002", author: user,
        text: "沿着海边散步，记录今天的蓝色。\nA quiet afternoon by the sea. مرحباً", images: images, createdAt: 1_790_000_000_000, likes: [user],
        comments: [.init(id: "comment", author: user, text: "下次再来。", createdAt: 1_790_000_010_000)])]
    static let images: [ChatAsset] = (1...9).map { index in
        ChatAsset(id: String(index), kind: "image", resources: [], width: 160, height: 120, duration: 0, animated: false, waveform: [], version: 1)
    }
    static func image(_ index: Int, size: CGSize = CGSize(width: 160, height: 120)) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor(hue: CGFloat(index) / 10, saturation: 0.35, brightness: 0.8, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("\(index)" as NSString).draw(at: CGPoint(x: size.width / 2 - 14, y: size.height / 2 - 20), withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.white])
        }
    }
    static func runtime(imageCount: Int = 9) -> MomentsRuntime {
        var post = posts[0]; post.images = Array(images.prefix(max(0, min(9, imageCount))))
        return MomentsRuntime(preview: [post], user: user.id)
    }
    /// 在同一真实列表中提供单图、四图和九图，便于模拟器手动对比。
    static func layoutComparisonRuntime() -> MomentsRuntime {
        let samples = [(1, "单图 · 保持原始比例"), (4, "四图 · 2×2 排列"), (9, "九图 · 网格最大宽度 320 pt")]
        let values = samples.map { count, title in
            var post = posts[0]
            post.id = String(format: "00000000-0000-0000-0000-%012d", count + 10)
            post.text = title; post.images = Array(images.prefix(count))
            return post
        }
        return MomentsRuntime(preview: values, user: user.id)
    }
}
#endif
